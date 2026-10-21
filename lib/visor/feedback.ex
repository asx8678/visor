defmodule Visor.Feedback do
  @moduledoc """
  A session's feedback collector. Tools report to it while they work, and
  it keeps what doesn't need to go to the model:

    * full outputs, behind short refs such as `r3`, which a script reads
      back with `V.output/2` when the short feedback isn't enough
    * the files the session changed, so a check lists only the warnings
      the agent caused, and the size and mtime Mix last saw for each, so
      a change Mix would miss can be made visible (see `V`)
    * the last check for each scope, so the next one can say what it
      fixed and what it broke

  It is deterministic: the same text always gets the same ref, and
  nothing depends on timing. Every function also works without a session
  (a script run on its own), where nothing is kept.
  """
  use GenServer

  alias Visor.Harness

  # Refs kept per session, and the bytes they may hold together; the
  # oldest goes first.
  @max_refs 50
  @max_bytes 20_000_000

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, id, name: Harness.via({id, :feedback}))
  end

  @doc "Keeps `text` and returns its ref, or nil when there is no session."
  def keep(session, text) when is_binary(text), do: call(session, {:keep, text}, nil)

  @doc "The text behind a ref."
  def fetch(session, ref) do
    call(session, {:fetch, ref}, {:error, "No outputs are kept outside a session."})
  end

  @doc """
  Records that the session changed a file, and returns the file's
  `{mtime, size}` as Mix last saw it: at the last check, or as it was
  `before` the session first changed it.
  """
  def changed(session, path, before), do: call(session, {:changed, path, before}, before)

  @doc "Records the `{mtime, size}` of files as Mix sees them at a check."
  def saw(nil, _stats), do: :ok
  def saw(session, stats), do: GenServer.cast(Harness.via({session, :feedback}), {:saw, stats})

  @doc "The files the session changed, sorted."
  def changed_files(session), do: call(session, :changed_files, [])

  @doc """
  Stores a check under its scope (the path it checked, or nil for the
  whole project) and returns the previous check for that scope.
  """
  def record_check(session, scope, check), do: call(session, {:check, scope, check}, nil)

  defp call(nil, _message, default), do: default

  defp call(session, message, default) do
    case GenServer.whereis(Harness.via({session, :feedback})) do
      nil -> default
      pid -> GenServer.call(pid, message)
    end
  end

  @impl true
  def init(id) do
    Process.set_label("feedback #{id}")

    {:ok,
     %{
       refs: %{},
       by_hash: %{},
       order: [],
       next: 1,
       bytes: 0,
       changed: MapSet.new(),
       seen: %{},
       checks: %{}
     }}
  end

  @impl true
  def handle_call({:keep, text}, _from, state) do
    hash = :crypto.hash(:sha256, text)

    case state.by_hash do
      %{^hash => ref} -> {:reply, ref, state}
      _ -> {:reply, "r#{state.next}", put_ref(state, "r#{state.next}", hash, text)}
    end
  end

  def handle_call({:fetch, ref}, _from, state) do
    case state.refs do
      %{^ref => {_hash, text}} ->
        {:reply, {:ok, text}, state}

      _ ->
        {:reply,
         {:error,
          "There is no output #{ref}. Only the latest #{@max_refs} outputs " <>
            "(up to #{div(@max_bytes, 1_000_000)} MB) are kept."}, state}
    end
  end

  def handle_call({:changed, path, before}, _from, state) do
    seen = Map.put_new(state.seen, path, before)
    {:reply, seen[path], %{state | changed: MapSet.put(state.changed, path), seen: seen}}
  end

  def handle_call(:changed_files, _from, state) do
    {:reply, state.changed |> MapSet.to_list() |> Enum.sort(), state}
  end

  def handle_call({:check, scope, check}, _from, state) do
    {:reply, state.checks[scope], put_in(state.checks[scope], check)}
  end

  @impl true
  def handle_cast({:saw, stats}, state) do
    {:noreply, %{state | seen: Map.merge(state.seen, stats)}}
  end

  defp put_ref(state, ref, hash, text) do
    evict(%{
      state
      | refs: Map.put(state.refs, ref, {hash, text}),
        by_hash: Map.put(state.by_hash, hash, ref),
        order: state.order ++ [ref],
        next: state.next + 1,
        bytes: state.bytes + byte_size(text)
    })
  end

  # Drops the oldest refs while there are too many or they hold too much,
  # always keeping the newest.
  defp evict(%{order: [oldest | rest], bytes: bytes} = state)
       when length(rest) >= @max_refs or (bytes > @max_bytes and rest != []) do
    {{hash, text}, refs} = Map.pop(state.refs, oldest)

    evict(%{
      state
      | refs: refs,
        by_hash: Map.delete(state.by_hash, hash),
        order: rest,
        bytes: bytes - byte_size(text)
    })
  end

  defp evict(state), do: state
end
