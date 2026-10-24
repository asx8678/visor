defmodule Visor.Code do
  @moduledoc """
  Code mode. The model writes one Elixir script that calls the tools as
  functions on `V`, and the whole script runs in a single process, so a
  step with many reads, searches and commands is one process and one model
  round trip instead of one per tool call.

  Scripts run in a Dune sandbox, which blocks File, System, processes,
  `apply` and other dynamic calls, leaving pure modules and `V`. Dune's
  own docs call the sandbox best-effort, so it guards against mistakes,
  not against a determined escape.

  Dune runs the script in a process of its own:

      tool elixir      the tool task, which holds the context
      └── sandbox      Dune's runner
          └── elixir script
  """

  alias Visor.Feedback
  alias Visor.Agent.Event

  # V.__begin__/0 finds the script's context and names its processes.
  @begin "V.__begin__(); "

  @opts [
    allowlist: Visor.Code.Allowlist,
    # Reductions include the work V does for the script (reading and
    # searching files), so this is high; the timeout is the real bound.
    max_reductions: 2_000_000_000,
    # In words, about 100 MB.
    max_heap_size: 12_500_000,
    # @begin doesn't count against the script.
    max_length: Visor.Limits.script_chars() + byte_size(@begin),
    pretty: true,
    # Maps print in key order, so the same value always reads the same.
    inspect_sort_maps: true
  ]

  @doc """
  Runs a script for the `elixir` tool and sums it up for the model (see
  `Visor.Feedback.Script`). `context` (`:session` and `:call_id`) routes
  the script's calls to the console and its long outputs to the session's
  feedback collector.
  """
  def run(code, context) do
    {status, text, _calls} = execute(code, context)
    {status, text}
  end

  @doc """
  Like `run/2`, and also returns the script's V calls (see `facts/1`).
  `context[:timeout_ms]` is the script's time limit (see `timeout_ms/1`).
  """
  def execute(code, context) do
    {result, calls} = evaluate(code, context)
    {status, text} = render(result, calls, context, code)
    {status, text, calls}
  end

  @doc """
  Like `execute/2`, continuing `session`, a `Dune.Session` that keeps one
  prompt's variables from script to script (after Vibe's stateful eval):
  returns the session after the script too, for the next one. A failed
  script leaves it as it was.
  """
  def execute(code, context, %Dune.Session{} = session) do
    {result, calls, session} = evaluate_in(code, context, session)
    {status, text} = render(result, calls, context, code)
    {status, text, calls, session}
  end

  # A script that didn't parse can only be hinted at from its code.
  defp render(result, calls, context, code) do
    {status, text} = Feedback.Script.render(result, calls, &Feedback.keep(context[:session], &1))

    case {result, Feedback.Hint.for_parse_error(code)} do
      {%Dune.Failure{type: :parsing}, hint} when is_binary(hint) ->
        {status, text <> "\nhint: " <> hint}

      _other ->
        {status, text}
    end
  end

  @doc """
  Runs a script and returns Dune's result and the script's V calls, for a
  caller that wants the value itself (`V.run/2`). It sets the context in
  the calling process, so a caller that has its own puts it back.
  """
  def evaluate(code, context) do
    {opts, table} = prepare(context)
    result = Dune.eval_string(@begin <> code, opts)
    log_script(context, result)
    {result, calls(table)}
  end

  defp evaluate_in(code, context, session) do
    {opts, table} = prepare(context)
    session = Dune.Session.eval_string(session, @begin <> code, opts)
    log_script(context, session.last_result)
    {session.last_result, calls(table), %{session | last_result: nil}}
  end

  # The script records its V calls in a table rather than in this
  # process's mailbox, which Dune waits in: a script can make thousands.
  # Its calls read the deadline to fit their own limits under it.
  defp prepare(context) do
    # Dune renames atoms a script uses that don't exist yet, so an option
    # only V knows, such as credo:, would reach V renamed unless V is
    # loaded before the script is parsed.
    {:module, V} = Code.ensure_loaded(V)
    timeout = Map.get(context, :timeout_ms) || Visor.Limits.script_timeout_ms()
    table = :ets.new(:visor_calls, [:public])
    deadline = System.monotonic_time(:millisecond) + timeout
    Process.put(__MODULE__, Map.merge(context, %{calls: table, deadline: deadline}))
    {Keyword.put(@opts, :timeout, timeout), table}
  end

  @doc """
  The variables `session` keeps, by their names in the script, each as
  `{name, value}`.
  """
  def kept(%Dune.Session{bindings: bindings, env: env}) do
    for {name, value} <- bindings, do: {Dune.AtomMapping.to_string(env.atom_mapping, name), value}
  end

  @doc """
  The time limit for a script whose call asked for `seconds` (nil for
  none): the default, raised to what was asked up to
  `Visor.Limits.max_script_timeout_ms/0`. A limit is never lowered.
  """
  def timeout_ms(seconds) when is_number(seconds) and seconds > 0 do
    asked = round(seconds * 1000)
    asked |> max(Visor.Limits.script_timeout_ms()) |> min(Visor.Limits.max_script_timeout_ms())
  end

  def timeout_ms(_seconds), do: Visor.Limits.script_timeout_ms()

  @doc """
  The milliseconds the running script has left, from inside it, or nil
  outside a script.
  """
  def time_left do
    with %{deadline: deadline} <- Process.get(__MODULE__),
         do: max(deadline - System.monotonic_time(:millisecond), 0)
  end

  @doc """
  What each of a script's V calls did, small enough to keep for the whole
  session: its call text, whether it worked, and the file, command or check
  it touched. `Visor.Compaction` sums up old steps from these.
  """
  def facts(calls), do: Enum.map(calls, &fact/1)

  defp fact(call) do
    %{
      name: call.name,
      text: call.text,
      status: call.status,
      path: path(call.name, call.args),
      error: call[:error] && first_line(call.error, 300),
      changed: call[:changed],
      ran: call[:ran] && first_line(call.ran, 200),
      started: call[:started],
      reverted: call[:reverted],
      exit: call[:exit],
      check: call[:value][:status],
      summary: call[:check] && first_line(call.check, 200)
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp path(name, [path | _]) when name in [:ls, :read, :exists?, :write, :edit, :glob, :check],
    do: path

  defp path(:grep, [_pattern, path]), do: path
  defp path(:grep, [_pattern]), do: "."
  defp path(_name, _args), do: nil

  defp first_line(text, max_bytes) do
    text |> String.split("\n", parts: 2) |> hd() |> Visor.Tools.truncate(max_bytes)
  end

  # The script's whole output and value, before the summary for the model
  # cuts them, for the session log.
  defp log_script(%{session: session, call_id: call_id}, result) do
    Event.broadcast(session, {:script_end, call_id, script_info(result)})
  end

  defp log_script(_context, _result), do: :ok

  defp script_info(%Dune.Success{} = success) do
    %{
      status: :ok,
      stdio: success.stdio,
      value: Feedback.Script.inspected(success, :infinity, :infinity)
    }
  end

  defp script_info(failure) do
    %{status: :error, type: failure.type, message: failure.message, stdio: failure.stdio}
  end

  # The script's V calls, each as its last report, including the one a
  # script stopped at its time limit was making.
  defp calls(table) do
    calls = table |> :ets.tab2list() |> Enum.map(&elem(&1, 1)) |> Enum.sort_by(& &1.n)
    :ets.delete(table)
    calls
  end

  @doc false
  # The context a runner stored, read by its script through `$ancestors`.
  def context(pid) do
    with {:dictionary, dictionary} <- Process.info(pid, :dictionary),
         {_key, context} <- List.keyfind(dictionary, __MODULE__, 0) do
      context
    else
      _ -> nil
    end
  end

  @doc false
  # Records one of a script's V calls for its runner, and sends it to the
  # console. A later report of the same call replaces the earlier.
  def report(context, call) do
    with %{calls: table} <- context, do: :ets.insert(table, {call.n, call})

    with %{session: session, call_id: call_id} <- context do
      Event.broadcast(session, {:code_call, call_id, call})
    end

    :ok
  end
end

defmodule Visor.Code.Allowlist do
  @moduledoc false
  use Dune.Allowlist, extend: Dune.Allowlist.Default

  allow V,
    only: [
      :__begin__,
      :ls,
      :glob,
      :exists?,
      :read,
      :image,
      :grep,
      :docs,
      :source,
      :calls,
      :write,
      :edit,
      :sh,
      :check,
      :output,
      :recall,
      :job,
      :jobs,
      :stop,
      :wait,
      :schedule,
      :remember,
      :memories,
      :forget,
      :goal,
      :tidewave,
      :carry,
      :compact,
      :context,
      :think,
      :attempt,
      :all,
      :note,
      :save,
      :run,
      :scripts,
      :agent,
      :council,
      :history,
      :history_entry,
      :beam_stats
    ]

  allow Path, only: [:join, :basename, :dirname, :extname, :rootname, :split]
end
