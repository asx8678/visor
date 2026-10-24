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

  @doc "Background jobs one session may run at once."
  def jobs_at_once, do: 8

  @doc "The end of a job's output its record keeps; the whole is in its file."
  def job_tail_bytes, do: 8_000

  @doc """
  Times jobs ending may start the agent on their own (a wake) between two
  prompts from the user.
  """
  def job_wakeups, do: 3

  @doc """
  How long the agent waits for more jobs to end before a wake (shorter in
  the tests, `config :visor, job_wake_batch_ms: ms`).
  """
  def job_wake_batch_ms, do: Application.get_env(:visor, :job_wake_batch_ms, 1_000)

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

  @doc "Calls `V.all/1` runs at once."
  def parallel_calls, do: 4

  @doc "Identical scripts in a row from which each result carries a warning."
  def repeat_warn, do: 3

  @doc "Identical scripts in a row at which the next one isn't run."
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

  @doc "Items the model may ask every summary to carry forward, and their length."
  def carry_items, do: 16
  def carry_chars, do: 300

  @doc "The largest summary a compaction writes."
  def summary_bytes, do: 32_768
end
