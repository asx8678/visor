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

  ## What the model sees

  @doc "A shell command's output kept, and a script's whole result."
  def result_bytes, do: 32_000

  @doc "A script's value, before it is cut and kept behind a ref."
  def value_bytes, do: 24_000

  @doc "What a script printed, before it is cut and kept behind a ref."
  def printed_bytes, do: 8_000
end
