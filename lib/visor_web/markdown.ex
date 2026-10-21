defmodule VisorWeb.Markdown do
  @moduledoc """
  Reads the Markdown that models write into a tree for HEEx to render, so
  model text never reaches the page as raw HTML.

  Blocks: fenced code, headings, lists, quotes, tables, rules and
  paragraphs. Inline: code, bold, italics, links and bare URLs, where only
  `http` and `https` links become links. Italics start only after a space
  or an opening bracket, so glob paths such as `lib/**/*.ex` stay as typed.

  Any text parses, including a reply cut off while it streams in: an
  unclosed fence runs to the end, and an unclosed `**` stays as typed.
  """

  @type inline ::
          String.t()
          | {:code, String.t()}
          | {:strong, [inline]}
          | {:em, [inline]}
          | {:link, String.t(), [inline]}

  @type block ::
          {:code, String.t(), String.t()}
          | {:heading, 1..3, [inline]}
          | {:paragraph, [inline]}
          | {:list, [{String.t(), non_neg_integer(), [inline]}]}
          | {:quote, [block]}
          | {:table, [[inline]] | nil, [[[inline]]]}
          | :rule

  @doc "Parses text into blocks."
  @spec parse(String.t()) :: [block]
  def parse(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.split("\n")
    |> blocks([])
  end

  defp blocks([], acc), do: Enum.reverse(acc)

  defp blocks([line | rest] = lines, acc) do
    cond do
      blank?(line) ->
        blocks(rest, acc)

      fence = Regex.run(~r/^\s{0,3}(`{3,}|~{3,})\s*([^`\s]*)/, line) ->
        [_, marker, lang] = fence
        {code, rest} = fenced(rest, marker, [])
        blocks(rest, [{:code, lang, code} | acc])

      heading = Regex.run(~r/^\s{0,3}(\#{1,6})\s+(.*?)(?:\s+#+)?\s*$/, line) ->
        [_, hashes, title] = heading
        blocks(rest, [{:heading, min(String.length(hashes), 3), inline(title)} | acc])

      line =~ ~r/^\s{0,3}([-*_])(\s*\1){2,}\s*$/ ->
        blocks(rest, [:rule | acc])

      quote?(line) ->
        {quoted, rest} = Enum.split_while(lines, &quote?/1)
        inner = Enum.map(quoted, &Regex.replace(~r/^\s{0,3}>\s?/, &1, ""))
        blocks(rest, [{:quote, blocks(inner, [])} | acc])

      item?(line) ->
        {items, rest} = list_items(lines, [])
        blocks(rest, [{:list, items} | acc])

      table?(lines) ->
        [_divider | rest] = rest
        {body, rest} = Enum.split_while(rest, &row?/1)
        blocks(rest, [{:table, cells(line), Enum.map(body, &cells/1)} | acc])

      true ->
        {more, rest} = Enum.split_while(rest, &paragraph_line?/1)
        para = [line | more] |> Enum.map(&String.trim/1) |> Enum.join("\n")
        blocks(rest, [{:paragraph, inline(para)} | acc])
    end
  end

  # Everything up to the closing fence, or to the end while it streams in.
  defp fenced([], _marker, acc), do: {acc |> Enum.reverse() |> Enum.join("\n"), []}

  defp fenced([line | rest], marker, acc) do
    if String.starts_with?(String.trim(line), marker) and String.trim(line) =~ ~r/^(`+|~+)$/,
      do: {acc |> Enum.reverse() |> Enum.join("\n"), rest},
      else: fenced(rest, marker, [line | acc])
  end

  defp blank?(line), do: String.trim(line) == ""
  defp quote?(line), do: line =~ ~r/^\s{0,3}>/
  defp item?(line), do: line =~ ~r/^\s*([-*+]|\d{1,9}[.)])\s+\S/

  defp row?(line), do: String.starts_with?(String.trim_leading(line), "|")

  defp table?([first, second | _]) do
    row?(first) and
      second =~ ~r/^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$/
  end

  defp table?(_lines), do: false

  # A paragraph runs until a blank line or the start of another block.
  defp paragraph_line?(line) do
    not (blank?(line) or quote?(line) or item?(line) or
           line =~ ~r/^\s{0,3}(`{3,}|~{3,}|\#{1,6}\s)/)
  end

  # Items keep their marker, so numbered lists keep the model's numbers,
  # and their depth from the indent. Indented lines join the item above;
  # a blank line ends the list unless another item follows.
  defp list_items([line | rest] = lines, acc) do
    case Regex.run(~r/^(\s*)([-*+]|\d{1,9}[.)])\s+(.*)$/, line) do
      [_, indent, marker, text] ->
        {more, rest} = Enum.split_while(rest, &continuation?/1)
        text = Enum.join([text | Enum.map(more, &String.trim/1)], " ")
        list_items(rest, [{marker, div(String.length(indent), 2), text} | acc])

      nil ->
        if blank?(line) and rest != [] and item?(hd(rest)),
          do: list_items(rest, acc),
          else: {finish_items(acc), lines}
    end
  end

  defp list_items([], acc), do: {finish_items(acc), []}

  defp continuation?(line), do: line =~ ~r/^\s{2,}\S/ and not item?(line)

  defp finish_items(acc) do
    acc
    |> Enum.reverse()
    |> Enum.map(fn {marker, depth, text} -> {bullet(marker), min(depth, 3), inline(text)} end)
  end

  defp bullet(marker) when marker in ["-", "*", "+"], do: "•"
  defp bullet(marker), do: String.replace(marker, ")", ".")

  defp cells(row) do
    row
    |> String.trim()
    |> String.trim_leading("|")
    |> String.trim_trailing("|")
    |> String.split("|")
    |> Enum.map(&(&1 |> String.trim() |> inline()))
  end

  @doc "Parses inline Markdown: code, bold, italics, links and bare URLs."
  @spec inline(String.t()) :: [inline]
  def inline(""), do: []

  def inline(text) do
    pattern =
      ~r/(`+)(.+?)\1|\*\*(?=\S)(.+?)(?<=\S)\*\*|__(?=\S)(.+?)(?<=\S)__|(?<![^\s(\["'])\*(?=[^\s*])(.+?)(?<=[^\s*])\*|(?<![\w\\])_(?=\S)(.+?)(?<=\S)_(?!\w)|\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)|https?:\/\/[^\s<>()]*[^\s<>().,;:!?'"*_]/s

    case Regex.run(pattern, text, return: :index) do
      nil ->
        [text]

      [{start, length} | groups] ->
        before = binary_part(text, 0, start)
        match = binary_part(text, start, length)
        rest = binary_part(text, start + length, byte_size(text) - start - length)
        node = node(Enum.map(groups, &slice(text, &1)) ++ List.duplicate(nil, 8), match)
        Enum.reject([before], &(&1 == "")) ++ [node | inline(rest)]
    end
  end

  defp slice(_text, {-1, _}), do: nil
  defp slice(text, {start, length}), do: binary_part(text, start, length)

  defp node([_ticks, code | _], _match) when is_binary(code), do: {:code, String.trim(code)}
  defp node([_, _, strong | _], _match) when is_binary(strong), do: {:strong, inline(strong)}
  defp node([_, _, _, strong | _], _match) when is_binary(strong), do: {:strong, inline(strong)}
  defp node([_, _, _, _, em | _], _match) when is_binary(em), do: {:em, inline(em)}
  defp node([_, _, _, _, _, em | _], _match) when is_binary(em), do: {:em, inline(em)}

  defp node([_, _, _, _, _, _, label, url | _], _match) when is_binary(url),
    do: {:link, url, inline(label)}

  defp node(_groups, url), do: {:link, url, [url]}
end
