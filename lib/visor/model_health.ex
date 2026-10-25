defmodule Visor.ModelHealth do
  @moduledoc """
  A circuit breaker for the model, after BeamAgent's per-node breakers:
  model calls that fail one after another, in any session, open it for
  `Visor.Limits.model_cooldown_ms/0`. While it is open, nothing starts a
  model call on its own (wakes, sub-agents, councils, reviews); the
  user's own prompts still go. A call that answers closes it, and the
  first call after the cooldown is the trial: if it fails, it opens again.

  A call fails when it errs, crashes or hangs past its deadline, a bad
  key and a missing model included. A request the provider refuses as
  malformed (`{:error, :rejected, _}`: HTTP 400, 422) or as too large
  (a 413, or a 400 that names the window) tells nothing of the provider, so it counts neither way
  (`record_result/1`).

  Its state is a table this process owns and alone writes, from the
  records sent to it; every agent reads it before a wake, so the reads
  don't wait on the process.
  """
  use GenServer

  alias Visor.Limits

  @table __MODULE__

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Records how a model call ended: `:ok` or `:error`."
  @spec record(:ok | :error) :: :ok
  def record(result) when result in [:ok, :error] do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, {:record, result})
    :ok
  end

  @doc """
  Records a provider's answer (what `Visor.Model`'s `stream/2` returned):
  `{:ok, _}` as `:ok`, a request it refused (`:rejected`,
  `:context_overflow`) as neither, anything else as `:error`.
  """
  @spec record_result(term()) :: :ok
  def record_result({:ok, _result}), do: record(:ok)

  def record_result({:error, refused, _message}) when refused in [:rejected, :context_overflow],
    do: :ok

  def record_result(_error), do: record(:error)

  @doc "Whether the breaker is open: nil, or the message for what it holds back."
  @spec open() :: String.t() | nil
  def open do
    with [{:opened, opened}] when is_integer(opened) <- :ets.lookup(@table, :opened),
         left when left > 0 <- opened + Limits.model_cooldown_ms() - now() do
      "The model failed #{Limits.model_failures()} times in a row, so for " <>
        "#{div(left + 999, 1000)} s more nothing starts a model call on its own."
    else
      _closed -> nil
    end
  rescue
    # Its process, and the table with it, is restarting. Closed is what
    # the restarted process starts as, so this lets through no more than
    # the new table will; and the breaker only holds back what starts on
    # its own, never the user's prompts.
    ArgumentError -> nil
  end

  @doc "Closes it."
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])
    close()
    {:ok, nil}
  end

  @impl true
  def handle_cast({:record, :ok}, state) do
    close()
    {:noreply, state}
  end

  def handle_cast({:record, :error}, state) do
    if :ets.update_counter(@table, :failures, 1) >= Limits.model_failures(),
      do: :ets.insert(@table, {:opened, now()})

    {:noreply, state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    close()
    {:reply, :ok, state}
  end

  defp close, do: :ets.insert(@table, [{:failures, 0}, {:opened, nil}])

  defp now, do: System.monotonic_time(:millisecond)
end
