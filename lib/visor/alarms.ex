defmodule Visor.Alarms do
  @moduledoc """
  The machine's alarms, after Vibe's system alarms: os_mon's for system
  memory and disk space (`config :os_mon` sets when they go off). While
  one is on, the console says so and nothing starts work on its own: no
  wake, background job or sub-agent. They are read every few seconds.

  The tests don't start os_mon, so the machine they run on raises none;
  a test sets one through `:alarm_handler`, which sasl runs.
  """
  use GenServer

  @topic "alarms"
  @every_ms 10_000

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The alarms that are on, each as a sentence."
  def active, do: :persistent_term.get({__MODULE__, :active}, [])

  @doc "Why nothing should start on its own now, or nil."
  def held do
    case active() do
      [] -> nil
      alarms -> Enum.join(alarms, "; ") <> ", so nothing starts on its own until that passes."
    end
  end

  @doc "Reads the alarms now and returns them (the tests' clock)."
  def check, do: GenServer.call(__MODULE__, :check)

  @doc "Subscribes the caller to `{:alarms, active}` when they change."
  def subscribe, do: Phoenix.PubSub.subscribe(Visor.PubSub, @topic)

  @impl true
  def init(nil) do
    # An interval, not a chain of send_after: a message that reaches this
    # process while Mix recompiles it in dev is dropped.
    :timer.send_interval(@every_ms, :check)
    {:ok, read([])}
  end

  @impl true
  def handle_info(:check, active), do: {:noreply, read(active)}

  @impl true
  def handle_call(:check, _from, active) do
    active = read(active)
    {:reply, active, active}
  end

  defp read(before) do
    active =
      try do
        :alarm_handler.get_alarms()
      catch
        # No alarm handler running (sasl not started).
        :exit, _no_handler -> []
      end
      |> Enum.flat_map(&describe/1)
      |> Enum.sort()

    if active != before do
      :persistent_term.put({__MODULE__, :active}, active)
      Phoenix.PubSub.broadcast(Visor.PubSub, @topic, {:alarms, active})
    end

    active
  end

  defp describe({:system_memory_high_watermark, _}), do: ["The machine is nearly out of memory"]
  defp describe({{:disk_almost_full, path}, _}), do: ["The disk at #{path} is nearly full"]
  # A process using a share of the memory is no reason to stop work.
  defp describe(_other), do: []
end
