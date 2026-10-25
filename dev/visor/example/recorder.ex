defmodule Visor.Example.Recorder do
  @max_text 200_000

  @moduledoc """
  Writes every event of the sessions `mix visor.example` watches to a
  JSON-lines file, one object a line:

    * `t` (UTC, to the millisecond), `session`, `label` (`offline`,
      `live`, `live/j1` for a sub-agent's), `event` (its name, such as
      `tool_end`) and `data` (the rest of it), for each event
    * `t`, `runner` (a step of the run, such as `check_start`) and its
      `data`, for the run's own steps

  It subscribes to every session's events as it starts, before any
  session does (`Visor.Agent.Event.subscribe_all/0`), so it has each
  session's from its first event, a sub-agent's included. A sub-agent's
  label is its parent's and its job's (`Visor.Harness.Session.parent/1`);
  a phase's session is named by `watch/3`, any other by its id. Pictures'
  bytes are left out, and text past #{@max_text} bytes is cut.
  """
  use GenServer

  @doc "Starts a recorder writing to `path`."
  @spec start_link(Path.t()) :: GenServer.on_start()
  def start_link(path), do: GenServer.start_link(__MODULE__, path)

  @doc "Names session `id`'s events `label` from now on."
  @spec watch(pid(), String.t(), String.t()) :: :ok
  def watch(recorder, id, label), do: GenServer.call(recorder, {:watch, id, label})

  @doc "Writes one of the run's own steps."
  @spec note(pid(), String.t(), term()) :: :ok
  def note(recorder, step, data \\ %{}), do: GenServer.cast(recorder, {:note, step, data})

  @doc """
  Returns once every event broadcast before the call is written: they
  reached the recorder's mailbox before the call did.
  """
  @spec sync(pid()) :: :ok
  def sync(recorder), do: GenServer.call(recorder, :sync)

  @doc "The sessions watched, as `{id, label}`, in the order they came."
  @spec sessions(pid()) :: [{String.t(), String.t()}]
  def sessions(recorder), do: GenServer.call(recorder, :sessions)

  @doc """
  A term as JSON holds it: structs and tuples as maps and lists, atoms,
  pids and refs as text, pictures as their type and size.
  """
  @spec jsonable(term()) :: term()
  def jsonable(%_{} = struct), do: struct |> Map.from_struct() |> jsonable()
  def jsonable(map) when is_map(map), do: Map.new(map, fn {k, v} -> {key(k), jsonable(v)} end)
  def jsonable(list) when is_list(list), do: list_items(list, [])
  def jsonable(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> jsonable()
  def jsonable(atom) when atom in [nil, true, false], do: atom
  def jsonable(atom) when is_atom(atom), do: Atom.to_string(atom)
  def jsonable(number) when is_number(number), do: number
  def jsonable(text) when is_binary(text), do: text(text)
  def jsonable(other), do: inspect(other)

  @impl true
  def init(path) do
    File.mkdir_p!(Path.dirname(path))
    # Before any session starts, so none of their events is missed.
    :ok = Visor.Agent.Event.subscribe_all()
    {:ok, %{io: File.open!(path, [:write, :binary]), labels: %{}, order: []}}
  end

  @impl true
  def handle_call({:watch, id, label}, _from, state),
    do: {:reply, :ok, name(state, id, label)}

  def handle_call(:sync, _from, state), do: {:reply, :ok, state}
  def handle_call(:sessions, _from, state), do: {:reply, state.order, state}

  @impl true
  def handle_cast({:note, step, data}, state) do
    write(state, %{"t" => now(), "runner" => step, "data" => jsonable(data)})
    {:noreply, state}
  end

  @impl true
  def handle_info({:agent, id, event}, state) do
    state = known(state, id)
    label = Map.fetch!(state.labels, id)
    [name | rest] = Tuple.to_list(event)
    data = if match?([_one], rest), do: hd(rest), else: rest

    write(state, %{
      "t" => now(),
      "session" => id,
      "label" => label,
      "event" => to_string(name),
      "data" => jsonable(data)
    })

    # A sub-agent its own session couldn't name (it had ended), named by
    # its parent's job.
    state =
      case event do
        {:job_start, %{kind: :agent, child: child} = job} when is_binary(child) ->
          if Map.get(state.labels, child, child) == child,
            do: name(state, child, "#{label}/#{job.id}"),
            else: state

        _other ->
          state
      end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # A session first seen: a sub-agent's under its parent's label and its
  # job, any other by its id until watch/3 names it.
  defp known(state, id) do
    cond do
      Map.has_key?(state.labels, id) ->
        state

      parent = Visor.Harness.Session.parent(id) ->
        label =
          case String.split(parent, "/", parts: 2) do
            [session, job] -> "#{Map.get(state.labels, session, session)}/#{job}"
            _other -> parent
          end

        name(state, id, label)

      true ->
        name(state, id, id)
    end
  end

  defp name(state, id, label) do
    case Map.fetch(state.labels, id) do
      {:ok, ^label} ->
        state

      known ->
        write(state, %{"t" => now(), "runner" => "watch", "data" => %{id: id, label: label}})

        order =
          if known == :error,
            do: state.order ++ [{id, label}],
            else: List.keystore(state.order, id, 0, {id, label})

        %{state | labels: Map.put(state.labels, id, label), order: order}
    end
  end

  defp write(state, line) do
    json =
      case Jason.encode(line) do
        {:ok, json} -> json
        {:error, error} -> Jason.encode!(%{"t" => now(), "unencodable" => inspect(error)})
      end

    IO.binwrite(state.io, [json, ?\n])
  end

  defp list_items([item | rest], acc), do: list_items(rest, [jsonable(item) | acc])
  defp list_items([], acc), do: Enum.reverse(acc)
  defp list_items(tail, acc), do: Enum.reverse([jsonable(tail) | acc])

  defp key(key) when is_binary(key), do: key
  defp key(key) when is_atom(key), do: Atom.to_string(key)
  defp key(key), do: inspect(key)

  defp text("data:image/" <> rest = text) do
    case String.split(rest, ";base64,", parts: 2) do
      [type, _base64] ->
        "[picture: image/#{type}, #{Visor.Format.number(byte_size(text))} bytes of base64]"

      _other ->
        text(String.slice(text, 0, 100))
    end
  end

  defp text(text) do
    cond do
      not String.valid?(text) ->
        "[#{Visor.Format.number(byte_size(text))} bytes, not text]"

      byte_size(text) > @max_text ->
        cut = text |> binary_part(0, @max_text) |> String.replace_invalid("")
        cut <> "… [cut: #{Visor.Format.number(byte_size(text))} bytes in all]"

      true ->
        text
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
end
