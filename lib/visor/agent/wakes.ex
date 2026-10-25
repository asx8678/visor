defmodule Visor.Agent.Wakes do
  @moduledoc """
  How many times the agent may wake between the user's prompts, and of what.

  A wake is a prompt the agent starts on its own. A wake that tells of a
  job's end or a supervisor's message (`:jobs`) counts against
  `Visor.Limits.job_wakeups/0`; one for a monitored job's new lines alone
  (`:monitor`) against `monitor_wakeups/0`, so monitors never use up the
  wakes a job's end needs. The user's prompt resets both, and Stop or a
  failed call holds them all until it.

  `proofs/wakes.ts` proves this with gdp-wired (`mix visor.proofs`):
  change the two together.

  The functions read and write the agent's state map: `:wakes`,
  `:monitor_wakes` and `:wakes_held`.
  """

  alias Visor.Limits

  @type kind :: :jobs | :monitor

  # How a prompt ends when it holds the wakes: Stop, or a failed call.
  @hold_reasons [:interrupted, :model_error, :model_crashed, :budget]
  @type limits :: %{jobs: non_neg_integer(), monitor: non_neg_integer()}

  @doc "The limits of each kind, from `Visor.Limits`."
  @spec limits() :: limits()
  def limits, do: %{jobs: Limits.job_wakeups(), monitor: Limits.monitor_wakeups()}

  @doc """
  What a wake would tell: `:jobs` when a job ended or a supervisor spoke,
  `:monitor` when it is only running jobs' new lines.
  """
  @spec kind(boolean()) :: kind()
  def kind(true), do: :jobs
  def kind(false), do: :monitor

  @doc "Whether a wake of `kind` may start: not held, and its count not spent."
  @spec allowed?(map(), kind(), limits()) :: boolean()
  def allowed?(state, kind, limits \\ limits()) do
    not Map.get(state, :wakes_held, false) and
      Map.get(state, field(kind), 0) < Map.fetch!(limits, kind)
  end

  @doc "Counts a wake of `kind` that started."
  @spec count(map(), kind()) :: map()
  def count(state, kind), do: Map.update(state, field(kind), 1, &(&1 + 1))

  @doc "The user's prompt: fresh counts, and nothing held."
  @spec reset(map()) :: map()
  def reset(state), do: Map.merge(state, %{wakes: 0, monitor_wakes: 0, wakes_held: false})

  @doc """
  Whether a prompt that ended for `reason` (`Visor.Agent.Event`'s
  `prompt_end`) holds the wakes: Stop or a failed call, the proof's
  `stop`. `Visor.Agent` asks this, so the two can't drift apart.
  """
  @spec holds?(atom()) :: boolean()
  def holds?(reason), do: reason in @hold_reasons

  @doc "Stop or a failed call: no wake until the user's next prompt."
  @spec hold(map()) :: map()
  def hold(state), do: Map.put(state, :wakes_held, true)

  defp field(:jobs), do: :wakes
  defp field(:monitor), do: :monitor_wakes
end
