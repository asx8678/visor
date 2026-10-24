defmodule Visor.ModelHealth do
  @moduledoc """
  A circuit breaker for the model, after BeamAgent's per-node breakers:
  model calls that fail one after another, in any session, open it for
  `Visor.Limits.model_cooldown_ms/0`. While it is open, nothing starts a
  model call on its own (wakes, sub-agents, councils, reviews); the
  user's own prompts still go. A call that answers closes it, and the
  first call after the cooldown is the trial: if it fails, it opens again.
  """
  use GenServer

  alias Visor.Limits

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Records how a model call ended: `:ok` or `:error`."
  def record(result) when result in [:ok, :error] do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, result)
    :ok
  end

  @doc "Whether the breaker is open: nil, or the message for what it holds back."
  def open do
    case Process.whereis(__MODULE__) && GenServer.call(__MODULE__, :open) do
      seconds when is_integer(seconds) ->
        "The model failed #{Limits.model_failures()} times in a row, so for #{seconds} s more " <>
          "nothing starts a model call on its own."

      _closed ->
        nil
    end
  end

  @doc "Closes it, for the tests."
  def reset, do: GenServer.call(__MODULE__, :reset)

  @impl true
  def init(nil), do: {:ok, %{failures: 0, opened: nil}}

  @impl true
  def handle_cast(:ok, state), do: {:noreply, %{state | failures: 0, opened: nil}}

  def handle_cast(:error, state) do
    failures = state.failures + 1
    opened = if failures >= Limits.model_failures(), do: now(), else: state.opened
    {:noreply, %{state | failures: failures, opened: opened}}
  end

  @impl true
  def handle_call(:open, _from, %{opened: nil} = state), do: {:reply, nil, state}

  def handle_call(:open, _from, state) do
    left = state.opened + Limits.model_cooldown_ms() - now()
    {:reply, if(left > 0, do: div(left + 999, 1000)), state}
  end

  def handle_call(:reset, _from, _state), do: {:reply, :ok, %{failures: 0, opened: nil}}

  defp now, do: System.monotonic_time(:millisecond)
end
