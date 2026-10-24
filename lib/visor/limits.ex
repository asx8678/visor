defmodule Visor.Limits do
  @moduledoc """
  How much an `elixir` script may do, and how much of what it did the
  model sees. Each is used in one place; they are gathered here so they
  can be read, and kept consistent, together.
  """

  ## What a script may do

  @doc "The largest file `V.read` and `V.edit` open."
  def read_bytes, do: 2_000_000

  @doc "The most lines one `V.grep` returns."
  def grep_matches, do: 1_000

  @doc "Files `V.grep` skips at this size or above."
  def grep_file_bytes, do: 1_000_000

  @doc "The most paths one `V.glob` returns."
  def glob_paths, do: 2_000

  @doc "The longest script the `elixir` tool runs, in characters."
  def script_chars, do: 20_000

  @doc "The most `V` calls one script may make."
  def v_calls, do: 2_000

  @doc "The largest image `V.image/1` or the console sends the model."
  def image_bytes, do: 5_000_000

  @doc "Pictures that may go with one model call."
  def images_per_call, do: 4

  @doc """
  Tokens an image is counted as for compaction: about what DeepSeek
  charged for a screenshot-sized one (a 16x16 picture was 184).
  """
  def image_tokens, do: 1_500

  @doc "The most of the project's AGENTS.md (or CLAUDE.md) the system prompt carries."
  def rules_bytes, do: 8_000

  @doc "When a shell command is killed, unless it asks for longer."
  def shell_timeout_ms, do: 60_000

  @doc "When a check's `mix test` is stopped, unless it asks for longer."
  def check_timeout_ms, do: 110_000

  @doc "When a script is stopped, unless the call asks for longer."
  def script_timeout_ms, do: 120_000

  @doc "The longest time limit a script may ask for."
  def max_script_timeout_ms, do: 15 * 60_000

  @doc """
  When the agent stops a tool call that is still running: Dune's own
  timeout (`script_ms`), then time for its sandbox to shut down and the
  result to render.
  """
  def tool_deadline_ms(script_ms \\ script_timeout_ms()), do: script_ms + 15_000

  @doc "When a background job is stopped, unless it asks for longer."
  def job_timeout_ms, do: 60 * 60_000

  @doc "The longest time limit a background job may ask for."
  def max_job_timeout_ms, do: 24 * 60 * 60_000

  @doc """
  When a monitored job (`V.sh(cmd, monitor: "text")`) is stopped, unless
  it asks for longer: pi-fabric's monitors last 5 minutes.
  """
  def monitor_timeout_ms, do: 5 * 60_000

  @doc "The longest time limit a monitored job may ask for."
  def max_monitor_timeout_ms, do: 30 * 60_000

  @doc """
  How often at most a monitored job's new lines reach the agent, together
  (shorter in the tests, `config :visor, monitor_interval_ms: ms`).
  """
  def monitor_interval_ms, do: Application.get_env(:visor, :monitor_interval_ms, 5_000)

  @doc "Background jobs one session may run at once."
  def jobs_at_once, do: 8

  @doc "The end of a job's output its record keeps; the whole is in its file."
  def job_tail_bytes, do: 8_000

  @doc """
  The most of a job's output its log file keeps, as pi-fabric's 8 MiB, so
  a job that prints without end can't fill the disk (shorter in the
  tests, `config :visor, job_log_bytes: n`).
  """
  def job_log_bytes, do: Application.get_env(:visor, :job_log_bytes, 8_000_000)

  @doc """
  Times jobs ending may start the agent on their own (a wake) between two
  prompts from the user.
  """
  def job_wakeups, do: 3

  @doc """
  Times a monitored job's new lines alone may wake the agent between two
  prompts from the user. A count of their own, so a monitor's lines never
  use up the wakes that tell of a job's end.
  """
  def monitor_wakeups, do: 3

  @doc """
  How long the agent waits for more jobs to end before a wake (shorter in
  the tests, `config :visor, job_wake_batch_ms: ms`).
  """
  def job_wake_batch_ms, do: Application.get_env(:visor, :job_wake_batch_ms, 1_000)

  @doc """
  How long a console's session outlives its page, for a reload to come
  back to it (0 ends it with the page; the tests set it with
  `config :visor, session_grace_ms: ms`).
  """
  def session_grace_ms, do: Application.get_env(:visor, :session_grace_ms, 5 * 60_000)

  @doc "How deep sub-agents may go: 1 lets a console's agent start them, not theirs."
  def agent_depth, do: 1

  @doc "Sub-agents one session may run at once."
  def agents_at_once, do: 3

  @doc "A sub-agent's model calls, unless it asks for fewer."
  def agent_steps, do: 12

  @doc "When a sub-agent is stopped, unless it asks for longer."
  def agent_timeout_ms, do: 20 * 60_000

  @doc "When the agent stops a model call that is still streaming."
  def model_deadline_ms, do: 20 * 60_000

  @doc """
  How long a model's response may send nothing at all (not even a
  keep-alive) before it counts as stalled.
  """
  def stream_idle_ms, do: 90_000

  ## What the model may spend

  @doc """
  The most a prompt from the user may spend in dollars, its wakes,
  reviews and sub-agents included: $1, or `VISOR_PROMPT_LIMIT_USD`. The
  dearest prompt in the live sessions so far cost $0.009; a full one, 24
  model calls near the compaction threshold, about $0.40.
  """
  def prompt_cost_limit, do: dollars("VISOR_PROMPT_LIMIT_USD", :prompt_cost_limit, 1.0)

  @doc "The most a session may spend in dollars: $5, or `VISOR_SESSION_LIMIT_USD`."
  def session_cost_limit, do: dollars("VISOR_SESSION_LIMIT_USD", :session_cost_limit, 5.0)

  @doc """
  The most tokens a prompt may use, in and out: a stop for a runaway
  prompt, also when the provider reports no cost.
  """
  def prompt_token_limit, do: 50_000_000

  defp dollars(env, key, default) do
    with nil <- Application.get_env(:visor, key),
         text when is_binary(text) <- System.get_env(env),
         {n, ""} when n > 0 <- Float.parse(text) do
      n
    else
      n when is_number(n) -> n / 1
      _unset -> default
    end
  end

  @doc "Model calls failing in a row, in any session, that open the breaker (`Visor.ModelHealth`)."
  def model_failures, do: 3

  @doc """
  How long the breaker stays open (0 in the tests, `config :visor,
  model_cooldown_ms: ms`, so one test's failures don't hold back another's).
  """
  def model_cooldown_ms, do: Application.get_env(:visor, :model_cooldown_ms, 60_000)

  ## What the model sees

  @doc "A shell command's output kept, and a script's whole result."
  def result_bytes, do: 32_000

  @doc "A script's value, before it is cut and kept behind a ref."
  def value_bytes, do: 24_000

  @doc "What a script printed, before it is cut and kept behind a ref."
  def printed_bytes, do: 8_000

  @doc "Progress notes one script may show (`V.note/1`); the rest are dropped."
  def script_notes, do: 50

  @doc "Reviews the reviewer makes per prompt from the user (`Visor.Reviewer`)."
  def reviews_per_prompt, do: 3

  @doc "The conversation's last messages a review sees."
  def review_messages, do: 12

  @doc "The newest session logs `V.history/2` reads, and the largest it reads."
  def history_logs, do: 50
  def history_log_bytes, do: 20_000_000

  @doc "Calls `V.all/1` runs at once."
  def parallel_calls, do: 4

  @doc "The most the variables a prompt's scripts keep for each other may hold."
  def kept_bytes, do: 20_000_000

  @doc "Identical scripts in a row from which each result carries a warning."
  def repeat_warn, do: 3

  @doc "Identical scripts in a row at which the last of them isn't run: the 6th is refused."
  def repeat_block, do: 6

  ## How the conversation is compacted (see `Visor.Compaction`)

  @doc """
  The context size that compacts the conversation, unless the provider
  sets its own (`DEEPSEEK_COMPACT_TOKENS`): this, or the window less
  `reserve_tokens/0`, whichever is smaller.
  """
  def compact_tokens, do: 200_000

  @doc "Room kept free in the context window for the next response."
  def reserve_tokens, do: 16_384

  @doc "Recent conversation kept as it was after a compaction, in tokens."
  def keep_recent_tokens, do: 20_000

  @doc "Notes a project keeps for its later sessions (`V.remember/1`), and their length."
  def memory_items, do: 50
  def memory_chars, do: 300

  @doc "Items the model may ask every summary to carry forward, and their length."
  def carry_items, do: 16
  def carry_chars, do: 300

  @doc "The largest summary a compaction writes."
  def summary_bytes, do: 32_768
end
