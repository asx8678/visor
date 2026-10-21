defmodule Visor.SessionLog do
  @moduledoc """
  Writes one console session's events to a JSON Lines file, so a session
  that went wrong can be read back afterwards (`mix visor.log`).

  Each session gets `log/sessions/<started>-<id>.jsonl` under the project
  (`config :visor, session_log_dir: path`, or `false` to turn logging
  off). The file is created with the session's first event, so a page
  opened and closed again leaves nothing behind.

  A line holds the local time (`at`), the milliseconds since the session
  started (`elapsed_ms`) and the `event`: prompts, model turns and their
  replies, tool calls and their results, script calls, status changes and
  notes. Long text is cut at #{64 * 1024} characters. Stream progress is
  kept to one line every few seconds per turn.

  The log runs beside its session rather than inside it, so a bug here
  never stops an agent, and an agent crash shows up in the log instead of
  ending it. It also records:

    * why the session stopped, including its console page closing or
      reloading while a prompt was running;
    * a `stall` line, with the stack of every busy process, when a
      running prompt sends no event for 30 seconds.
  """
  use GenServer, restart: :temporary

  require Logger

  alias Visor.{Agent, Harness, Model}

  @supervisor Visor.SessionLogs
  @max_chars 64 * 1024
  @stream_every_ms 5_000
  @tick_ms 10_000
  @stall_after_ms 30_000

  @doc "The directory session logs go to, or `nil` when logging is off."
  def dir do
    case Application.get_env(:visor, :session_log_dir, "log/sessions") do
      dir when is_binary(dir) -> Path.expand(dir)
      _off -> nil
    end
  end

  @doc """
  Starts logging session `id`, whose supervisor is `session` and whose
  console is `owner`. Does nothing when `dir` is `nil`.
  """
  def start(id, owner, session, dir) do
    if dir do
      DynamicSupervisor.start_child(
        @supervisor,
        {__MODULE__, id: id, owner: owner, session: session, dir: dir}
      )
    else
      :ignore
    end
  end

  @doc "The log file of a running session, or `nil`."
  def path(id) do
    case Registry.lookup(Harness.Registry, {id, :log}) do
      [{_pid, path}] -> path
      [] -> nil
    end
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    dir = Keyword.fetch!(opts, :dir)
    Process.set_label("session log #{id}")
    # Exits arrive as messages, so a shutdown still writes its last line.
    Process.flag(:trap_exit, true)

    stamp = Calendar.strftime(NaiveDateTime.local_now(), "%Y-%m-%dT%H%M%S")
    path = Path.join(dir, "#{stamp}-#{id}.jsonl")

    with :ok <- File.mkdir_p(dir),
         {:ok, _owner} <- Registry.register(Harness.Registry, {id, :log}, path) do
      :ok = Agent.subscribe(id)
      owner = Keyword.fetch!(opts, :owner)
      session = Keyword.fetch!(opts, :session)

      state = %{
        id: id,
        path: path,
        started: now(),
        owner: owner,
        owner_ref: Process.monitor(owner),
        session_ref: Process.monitor(session),
        agent: nil,
        status: :idle,
        last_event: now(),
        stall_logged: nil,
        stream_logged: %{},
        # Busy model and tool processes by pid, for the stall line.
        running: %{},
        tick_ms: Keyword.get(opts, :tick_ms, @tick_ms),
        stall_after_ms: Keyword.get(opts, :stall_after_ms, @stall_after_ms),
        # The first line, until the first event writes it.
        pending_start: nil
      }

      provider = Model.current().info()

      start =
        line(state, "start", %{
          session: id,
          provider: provider.provider,
          model: provider.model,
          endpoint: provider.endpoint,
          workspace: Visor.Tools.workspace(),
          owner: owner
        })

      state = %{state | pending_start: start}
      schedule_tick(state)
      {:ok, watch_agent(state)}
    else
      {:error, reason} ->
        Logger.warning("No session log for #{id} in #{dir}: #{inspect(reason)}")
        :ignore
    end
  end

  @impl true
  def handle_info({:agent, event}, state) do
    state = %{started(watch_agent(state)) | last_event: now(), stall_logged: nil}

    try do
      {:noreply, record(event, track(event, state))}
    rescue
      error ->
        write(state, "unrecorded", %{term: event, error: Exception.message(error)})
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{owner_ref: ref} = state) do
    running = running_labels(state)

    text =
      if state.status == :idle,
        do: "The console page closed or reloaded, so the session stops.",
        else:
          "The console page closed or reloaded while the session was busy (#{state.status}), " <>
            "so the session stops and its work is lost."

    if state.status != :idle, do: Logger.warning("Session #{state.id}: #{text}")

    if state.pending_start == nil do
      write(state, "owner_down", %{
        text: text,
        reason: reason,
        status: state.status,
        running: running
      })
    end

    {:noreply, %{state | owner_ref: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{session_ref: ref} = state) do
    if state.pending_start == nil,
      do: write(state, "stop", %{reason: reason, status: state.status})

    {:stop, :normal, state}
  end

  # The agent stops normally when its owner goes away; the session's own
  # :DOWN follows.
  def handle_info({:DOWN, ref, :process, pid, :normal}, %{agent: {pid, ref}} = state),
    do: {:noreply, %{state | agent: nil}}

  def handle_info({:DOWN, ref, :process, pid, reason}, %{agent: {pid, ref}} = state) do
    state = started(state)

    write(state, "agent_down", %{
      text: "The agent crashed. Its supervisor starts a new one with an empty conversation.",
      reason: reason,
      status: state.status,
      running: running_labels(state)
    })

    {:noreply, %{state | agent: nil, status: :idle, running: %{}}}
  end

  def handle_info(:tick, state) do
    schedule_tick(state)
    {:noreply, state |> watch_agent() |> check_stall()}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    # A session that stops on its own writes `stop` from its :DOWN; this
    # covers the log itself being shut down first, as at server shutdown.
    if reason != :normal and state.pending_start == nil,
      do: write(state, "log_stop", %{reason: reason, status: state.status})
  end

  defp started(%{pending_start: nil} = state), do: state

  defp started(state) do
    append(state, state.pending_start)
    %{state | pending_start: nil}
  end

  # Remembers what is running, for the stall check and `owner_down`.
  defp track({:status, status}, state), do: %{state | status: status}

  defp track({:turn_start, %{turn: turn, pid: pid}}, state),
    do: %{state | running: Map.put(state.running, pid, "model turn #{turn}")}

  defp track({:turn_end, %{turn: turn}}, state) do
    running = Map.reject(state.running, fn {_pid, label} -> label == "model turn #{turn}" end)
    %{state | running: running, stream_logged: Map.delete(state.stream_logged, turn)}
  end

  defp track({:tool_start, %{pid: pid, name: name, id: id}}, state),
    do: %{state | running: Map.put(state.running, pid, "tool #{name} #{id}")}

  defp track({:tool_end, %{name: name, id: id}}, state) do
    label = "tool #{name} #{id}"
    %{state | running: Map.reject(state.running, fn {_pid, l} -> l == label end)}
  end

  defp track(_event, state), do: state

  defp record({:user, text}, state), do: logged(state, "user", %{text: text})

  defp record({:turn_start, info}, state) do
    logged(state, "turn_start", %{
      turn: info.turn,
      model: info.provider[:model],
      effort: info.effort,
      thinking: info.thinking,
      messages: info.messages,
      pid: info.pid
    })
  end

  # Snapshots arrive every 80 ms with the whole reply so far; keep the
  # first one (the first token) and then one every few seconds, as sizes.
  defp record({:stream, turn, snapshot}, state) do
    last = state.stream_logged[turn]

    if last == nil or now() - last >= @stream_every_ms do
      write(state, "stream", %{
        turn: turn,
        chunks: snapshot.chunks,
        content_chars: String.length(snapshot.content || ""),
        reasoning_chars: String.length(snapshot.reasoning || ""),
        tool_calls:
          for call <- snapshot.tool_calls || [] do
            %{name: call.name, argument_chars: String.length(call.arguments || "")}
          end
      })

      %{state | stream_logged: Map.put(state.stream_logged, turn, now())}
    else
      state
    end
  end

  defp record({:turn_end, %{final: final} = info}, state) do
    logged(state, "turn_end", %{
      turn: info.turn,
      finish_reason: info.finish_reason,
      model: info.model,
      ms: info.ms,
      ttft_ms: info.ttft_ms,
      chunks: info.chunks,
      usage: info.usage,
      reasoning: final.reasoning,
      content: final.content,
      tool_calls: final.tool_calls
    })
  end

  defp record({:turn_end, info}, state), do: logged(state, "turn_end", info)

  defp record({:tool_start, call}, state) do
    logged(state, "tool_start", Map.take(call, [:id, :name, :arguments, :pid]))
  end

  defp record({:tool_end, call}, state) do
    logged(state, "tool_end", Map.take(call, [:id, :name, :status, :ms, :result]))
  end

  defp record({:code_call, call_id, call}, state),
    do: logged(state, "code_call", Map.put(call, :call_id, call_id))

  defp record({:status, status}, state), do: logged(state, "status", %{status: status})

  defp record({:note, level, text}, state),
    do: logged(state, "note", %{level: level, text: text})

  defp record({:settings, settings}, state),
    do: logged(state, "settings", Map.take(settings, [:effort, :thinking]))

  defp record({:context, messages}, state),
    do: logged(state, "context", %{messages: messages})

  # The request preview repeats what turn_start and the earlier lines hold.
  defp record({:request, _turn, _preview}, state), do: state

  defp record(event, state), do: logged(state, "event", %{term: event})

  defp logged(state, event, fields) do
    write(state, event, fields)
    state
  end

  # The agent starts after this log and again after a crash, so it is
  # looked up when needed rather than once.
  defp watch_agent(%{agent: nil, id: id} = state) do
    case GenServer.whereis(Harness.via({id, :agent})) do
      pid when is_pid(pid) -> %{state | agent: {pid, Process.monitor(pid)}}
      nil -> state
    end
  end

  defp watch_agent(state), do: state

  defp check_stall(%{status: :idle} = state), do: state

  defp check_stall(state) do
    quiet = now() - state.last_event
    since_logged = if state.stall_logged, do: now() - state.stall_logged

    if quiet >= state.stall_after_ms and
         (since_logged == nil or since_logged >= state.stall_after_ms) do
      agent = for {pid, _ref} <- List.wrap(state.agent), do: {pid, "agent"}
      processes = for {pid, label} <- agent ++ Enum.to_list(state.running), do: info(pid, label)

      write(state, "stall", %{
        text: "No event for #{div(quiet, 1000)} s while #{state.status}.",
        quiet_ms: quiet,
        status: state.status,
        processes: processes
      })

      %{state | stall_logged: now()}
    else
      state
    end
  end

  defp info(pid, label) do
    case Process.info(pid, [:status, :message_queue_len, :current_stacktrace]) do
      nil ->
        %{label: label, pid: pid, alive: false}

      info ->
        %{
          label: label,
          pid: pid,
          status: info[:status],
          message_queue_len: info[:message_queue_len],
          stacktrace: Enum.map(info[:current_stacktrace], &Exception.format_stacktrace_entry/1)
        }
    end
  end

  defp running_labels(state), do: state.running |> Map.values() |> Enum.sort()

  defp write(state, event, fields), do: append(state, line(state, event, fields))

  defp append(state, line) do
    case File.write(state.path, [line, ?\n], [:append]) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Session log #{state.path}: #{inspect(reason)}")
    end
  end

  defp line(state, event, fields) do
    head = [{"at", json(local_time())}, {"elapsed_ms", now() - state.started}, {"event", event}]

    # A field named like a head key (a script call's info can hold any
    # key) is kept under another name rather than shadowing it.
    pairs =
      for {key, value} <- Enum.sort(Map.to_list(fields)) do
        key = key(key)
        {if(key in ~w(at elapsed_ms event), do: "field_" <> key, else: key), json(value)}
      end

    try do
      Jason.encode!(Jason.OrderedObject.new(head ++ pairs))
    rescue
      error ->
        Jason.encode!(%{
          "at" => NaiveDateTime.to_iso8601(local_time()),
          "event" => event,
          "unencodable" => inspect(fields, limit: 50, printable_limit: 4096),
          "error" => Exception.message(error)
        })
    end
  end

  @doc false
  # Turns any term into something JSON can hold: maps and lists keep their
  # shape, long text is cut, and pids, tuples and the like are inspected.
  def json(%NaiveDateTime{} = time), do: NaiveDateTime.to_iso8601(time)
  def json(%_{} = struct), do: inspect(struct, limit: 50)
  def json(map) when is_map(map), do: Map.new(map, fn {k, v} -> {key(k), json(v)} end)
  def json(list) when is_list(list), do: Enum.map(list, &json/1)
  def json(value) when is_binary(value), do: text(value)
  def json(value) when is_number(value) or is_boolean(value) or is_nil(value), do: value
  def json(value) when is_atom(value), do: Atom.to_string(value)
  def json(value), do: inspect(value, limit: 50)

  defp key(key) when is_binary(key), do: key
  defp key(key) when is_atom(key), do: Atom.to_string(key)
  defp key(key), do: inspect(key)

  defp text(value) do
    cond do
      not String.valid?(value) ->
        inspect(value, limit: 50, printable_limit: @max_chars)

      byte_size(value) > @max_chars and String.length(value) > @max_chars ->
        cut = String.length(value) - @max_chars
        String.slice(value, 0, @max_chars) <> "… [#{cut} more characters cut]"

      true ->
        value
    end
  end

  # Local time to the millisecond, to line up with the server log.
  defp local_time do
    ms = System.os_time(:millisecond)

    ms
    |> div(1000)
    |> :calendar.system_time_to_local_time(:second)
    |> NaiveDateTime.from_erl!({rem(ms, 1000) * 1000, 3})
  end

  defp schedule_tick(state), do: Process.send_after(self(), :tick, state.tick_ms)

  defp now, do: System.monotonic_time(:millisecond)
end
