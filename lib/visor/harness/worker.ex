defmodule Visor.Harness.Worker do
  @moduledoc """
  A demo worker: does a little CPU work on a timer, then exits normally.
  Restarted by its supervisor only if it crashes.
  """
  use GenServer, restart: :transient

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    n = Keyword.fetch!(opts, :n)
    Process.set_label("worker #{n}")
    Process.send_after(self(), :done, Keyword.fetch!(opts, :duration_ms))
    schedule_tick()
    {:ok, %{n: n, ticks: 0}}
  end

  @impl true
  def handle_info(:tick, state) do
    # Enough work to register as activity in the process view.
    _ = Enum.reduce(1..:rand.uniform(40_000), 0, &(&1 + &2))
    schedule_tick()
    {:noreply, %{state | ticks: state.ticks + 1}}
  end

  def handle_info(:done, state), do: {:stop, :normal, state}

  defp schedule_tick, do: Process.send_after(self(), :tick, 120 + :rand.uniform(400))
end
