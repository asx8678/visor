defmodule Visor.Lock do
  @moduledoc """
  Locks that every console session shares, so two sessions working in the
  same project don't step on each other:

    * `{:file, path}`, held while `V.write/2` or `V.edit/3` reads, changes
      and writes a file, so neither writes over the other's change
    * `{:check, root}`, held while `V.check/1` runs the project's tests,
      since two `mix test` runs in one project share their build and
      `tmp_dir` folders

  One process holds a key at a time and the others wait their turn, in
  the order they asked. A holder that exits frees its key. A lock isn't
  reentrant: a holder that asks for its own key again waits forever.
  """
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc """
  Runs `fun` while holding `key`, waiting for it first if another process
  holds it. When the lock server isn't running (a server started before
  this module existed, with the module hot-loaded since), `fun` runs
  unlocked.
  """
  def hold(key, fun) do
    case GenServer.whereis(__MODULE__) do
      nil ->
        fun.()

      server ->
        :ok = GenServer.call(server, {:acquire, key}, :infinity)

        try do
          fun.()
        after
          GenServer.cast(server, {:release, key, self()})
        end
    end
  end

  # Each held key maps to {holder, monitor ref, queue of waiting callers}.
  @impl true
  def init(locks), do: {:ok, locks}

  @impl true
  def handle_call({:acquire, key} = request, {pid, _tag} = from, locks) do
    case locks do
      # A holder whose exit went unseen, as when its :DOWN reached this
      # server while Mix recompiled it, frees its key first.
      %{^key => {holder, ref, waiting}} ->
        if Process.alive?(holder),
          do: {:noreply, Map.put(locks, key, {holder, ref, :queue.in(from, waiting)})},
          else: handle_call(request, from, release(locks, key, holder))

      _free ->
        {:reply, :ok, Map.put(locks, key, {pid, Process.monitor(pid), :queue.new()})}
    end
  end

  @impl true
  def handle_cast({:release, key, pid}, locks), do: {:noreply, release(locks, key, pid)}

  # A holder that exits without releasing, such as a script stopped at its
  # time limit. A waiter that exited gets the key, and this, in its turn.
  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, locks) do
    case Enum.find(locks, fn {_key, {holder, _ref, _waiting}} -> holder == pid end) do
      {key, _lock} -> {:noreply, release(locks, key, pid)}
      nil -> {:noreply, locks}
    end
  end

  defp release(locks, key, pid) do
    case locks do
      %{^key => {^pid, ref, waiting}} ->
        Process.demonitor(ref, [:flush])

        case :queue.out(waiting) do
          {{:value, {next, _tag} = from}, rest} ->
            GenServer.reply(from, :ok)
            Map.put(locks, key, {next, Process.monitor(next), rest})

          {:empty, _none} ->
            Map.delete(locks, key)
        end

      _not_held ->
        locks
    end
  end
end
