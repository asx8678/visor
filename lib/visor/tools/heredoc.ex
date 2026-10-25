defmodule Visor.Tools.Heredoc do
  @moduledoc """
  Puts right a heredoc whose text starts on its opening line, as Python's
  triple quotes allow and Elixir refuses: `~S\"""  def f do\"""` on one
  line, or `\"""text` with its closing further down. In live runs it was
  the commonest way a script failed (6 of 15 in one, 3 of 7 in another),
  through the hint and the tool description's advice, so `Visor.Tools`
  reads it as meant, as it reads its other shapes:

    * text whose closing starts a later line: the text moves to its own
      line, and the heredoc holds what it then says in Elixir
    * text whose closing follows other text, on its line or a later one:
      exactly the text between them, as a sigil with delimiters the text
      doesn't hold (`~S[...]`), or else as a heredoc without its last
      newline

  A plain `\"""` or `'''` reads as `~s`, a string. The script is parsed
  without making atoms, put right only where the parser stops at such an
  opening, and kept only if it then parses.
  """

  # Delimiters a one-line sigil may take, in the order tried.
  @pairs [{"[", "]"}, {"{", "}"}, {"(", ")"}, {"<", ">"}, {"|", "|"}, {"/", "/"}]
  @tries 20
  # Past this, a script is left for its error: each try parses it whole,
  # in the agent's process.
  @max_bytes 64_000

  @doc """
  The script with each such heredoc put right, or nil when it has none or
  can't be. It runs in the agent's process (`Visor.Tools.prepare/1`), so
  nothing in it raises: a script it can't read is left for its error.
  """
  @spec repair(String.t()) :: String.t() | nil
  def repair(code) when is_binary(code) do
    if byte_size(code) <= @max_bytes and String.contains?(code, [~s("""), "'''"]),
      do: repair(code, @tries, false)
  rescue
    _error -> nil
  end

  defp repair(code, tries, fixed?) do
    case parse(code) do
      :ok ->
        if fixed?, do: code

      {:opening, line, column} when tries > 0 ->
        with fixed when is_binary(fixed) <- fix_at(code, line, column),
             do: repair(fixed, tries - 1, true)

      _other ->
        nil
    end
  end

  # Names and atoms stay strings, so model code never adds an atom.
  defp parse(code) do
    encoder = fn token, _meta -> {:ok, token} end

    # Quietly: the script's own warnings are the sandbox's to report.
    opts = [static_atoms_encoder: encoder, existing_atoms_only: true, emit_warnings: false]

    case Code.string_to_quoted(code, opts) do
      {:ok, _ast} ->
        :ok

      {:error, {meta, "heredoc allows only whitespace characters" <> _, _token}} ->
        {:opening, meta[:line], meta[:column]}

      _error ->
        :other
    end
  rescue
    _error -> :other
  end

  defp fix_at(code, line, column) when is_integer(line) and line > 0 do
    {before, [text | rest]} = code |> String.split("\n") |> Enum.split(line - 1)

    with {prefix, sigil, delim, after_opening} <- opening(text, column),
         closing when closing != nil <- closing(after_opening, rest, delim) do
      lines =
        case closing do
          # The closing starts a later line: the text gets its own line.
          {:own_line, rest} ->
            [prefix <> sigil(sigil, delim) <> delim, after_opening | rest]

          {:after_text, content, tail, rest} ->
            [prefix <> literal(sigil(sigil, delim), delim, content) <> tail | rest]
        end

      Enum.join(before ++ lines, "\n")
    end
  end

  defp fix_at(_code, _line, _column), do: nil

  # The opening the parser stopped at: the last one at or before its
  # column (counted in characters), with the sigil before it, if any.
  defp opening(text, column) do
    limit = if column, do: text |> String.slice(0, column) |> byte_size(), else: byte_size(text)

    starts =
      for [{start, 3}] <- Regex.scan(~r/"""|'''/, text, return: :index), start < limit, do: start

    with start when is_integer(start) <- List.last(starts) do
      delim = binary_part(text, start, 3)
      after_opening = binary_part(text, start + 3, byte_size(text) - start - 3)
      prefix = binary_part(text, 0, start)

      # Other sigils (~r, ~w, ...) are left to their error.
      case String.split_at(prefix, -2) do
        {prefix, sigil} when sigil in ["~S", "~s"] -> {prefix, sigil, delim, after_opening}
        {_prefix, "~" <> _letter} -> nil
        _none -> if prefix =~ ~r/~[a-zA-Z]+$/, do: nil, else: {prefix, nil, delim, after_opening}
      end
    end
  end

  # Where the text ends: on the opening's line, or the first later line
  # that holds the delimiter.
  defp closing(after_opening, rest, delim) do
    case :binary.match(after_opening, delim) do
      {at, 3} ->
        {:after_text, binary_part(after_opening, 0, at), cut(after_opening, at), rest}

      :nomatch ->
        case Enum.find_index(rest, &String.contains?(&1, delim)) do
          nil ->
            nil

          i ->
            {middle, [last | rest]} = Enum.split(rest, i)
            {at, 3} = :binary.match(last, delim)
            head = binary_part(last, 0, at)

            if String.trim(head) == "",
              do: {:own_line, middle ++ [last | rest]},
              else:
                {:after_text, Enum.join([after_opening | middle] ++ [head], "\n"), cut(last, at),
                 rest}
        end
    end
  end

  defp cut(text, at), do: binary_part(text, at + 3, byte_size(text) - at - 3)

  # A plain heredoc reads as a string: `'''` alone would be a charlist.
  defp sigil(nil, "'''"), do: "~s"
  defp sigil(nil, ~s(""")), do: ""
  defp sigil(sigil, _delim), do: sigil

  defp literal(sigil, delim, content) do
    sigil = if sigil == "", do: "~s", else: sigil

    case Enum.find(@pairs, fn {open, close} -> not String.contains?(content, [open, close]) end) do
      {open, close} ->
        sigil <> open <> content <> close

      nil ->
        "String.replace_suffix(" <>
          sigil <> delim <> "\n" <> content <> "\n" <> delim <> ~S|, "\n", "")|
    end
  end
end
