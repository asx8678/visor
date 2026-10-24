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

  @doc "When a shell command is killed."
  def shell_timeout_ms, do: 60_000

  @doc "When a script is stopped."
  def script_timeout_ms, do: 120_000

  @doc """
  When the agent stops a tool call that is still running: Dune's own
  timeout, then time for its sandbox to shut down and the result to render.
  """
  def tool_deadline_ms, do: script_timeout_ms() + 15_000

  @doc "When the agent stops a model call that is still streaming."
  def model_deadline_ms, do: 20 * 60_000

  ## What the model sees

  @doc "A shell command's output kept, and a script's whole result."
  def result_bytes, do: 32_000

  @doc "A script's value, before it is cut and kept behind a ref."
  def value_bytes, do: 24_000

  @doc "What a script printed, before it is cut and kept behind a ref."
  def printed_bytes, do: 8_000

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

  @doc "The largest summary a compaction writes."
  def summary_bytes, do: 32_768
end
