defmodule Visor.Content do
  @moduledoc """
  A message's content: text, or a list of parts when it carries images
  (OpenAI's format, which DeepSeek's Flash models read through zro):
  `%{"type" => "text", "text" => ...}` and `%{"type" => "image_url",
  "image_url" => %{"url" => "data:image/png;base64,..."}}`. What reads or
  extends content goes through here, so a list is never taken for text.
  """

  @doc "The text of content, an image's place in it marked as [image]."
  def text(text) when is_binary(text), do: text

  def text(parts) when is_list(parts) do
    Enum.map_join(parts, fn
      %{"type" => "text", "text" => text} -> text
      %{"type" => "image_url"} -> "[image]"
      _other -> ""
    end)
  end

  def text(_none), do: ""

  @doc "How many images content carries."
  def images(parts) when is_list(parts),
    do: Enum.count(parts, &match?(%{"type" => "image_url"}, &1))

  def images(_text), do: 0

  @doc "Content with `more` (text or parts) after it, a blank line between."
  def append(content, more), do: join(content, "\n\n", more)

  @doc "Content with `text` before it, a blank line between."
  def prepend(text, content), do: join(text, "\n\n", content)

  defp join(a, sep, b) when is_binary(a) and is_binary(b), do: a <> sep <> b
  defp join(a, sep, b), do: merge(parts(a) ++ [text_part(sep)] ++ parts(b))

  @doc "Text and images as one message's content: the text alone when there are none."
  def with_images(text, []), do: text
  def with_images(text, images), do: [text_part(text) | images]

  @doc "An image part for a picture's bytes."
  def image(mime, data),
    do: %{
      "type" => "image_url",
      "image_url" => %{"url" => "data:#{mime};base64," <> Base.encode64(data)}
    }

  @doc "A picture's type from its first bytes: PNG, JPEG, GIF or WebP; nil for anything else."
  def mime(<<0x89, "PNG", _::binary>>), do: "image/png"
  def mime(<<0xFF, 0xD8, 0xFF, _::binary>>), do: "image/jpeg"
  def mime(<<"GIF8", _::binary>>), do: "image/gif"
  def mime(<<"RIFF", _size::binary-size(4), "WEBP", _::binary>>), do: "image/webp"
  def mime(_other), do: nil

  defp parts(text) when is_binary(text), do: [text_part(text)]
  defp parts(parts) when is_list(parts), do: parts

  defp text_part(text), do: %{"type" => "text", "text" => text}

  # Text parts next to each other become one.
  defp merge(parts) do
    parts
    |> Enum.reduce([], fn
      %{"type" => "text", "text" => b}, [%{"type" => "text", "text" => a} | rest] ->
        [text_part(a <> b) | rest]

      part, acc ->
        [part | acc]
    end)
    |> Enum.reverse()
  end
end
