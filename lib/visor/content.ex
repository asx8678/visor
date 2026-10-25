defmodule Visor.Content do
  @moduledoc """
  A message's content: text, or a list of parts when it carries images
  (OpenAI's format, which DeepSeek's Flash models read through zro):
  `%{"type" => "text", "text" => ...}` and `%{"type" => "image_url",
  "image_url" => %{"url" => "data:image/png;base64,..."}}`. What reads or
  extends content goes through here, so a list is never taken for text.
  """

  @typedoc "A message's content: text, or text and image parts."
  @type t :: String.t() | [map()]

  @doc "The text of content, an image's place in it marked as [image]."
  @spec text(t() | nil) :: String.t()
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
  @spec images(t() | nil) :: non_neg_integer()
  def images(parts) when is_list(parts),
    do: Enum.count(parts, &match?(%{"type" => "image_url"}, &1))

  def images(_text), do: 0

  @doc "Content with `more` (text or parts) after it, a blank line between."
  @spec append(t(), t()) :: t()
  def append(content, more), do: join(content, "\n\n", more)

  @doc "Content with `text` before it, a blank line between."
  @spec prepend(t(), t()) :: t()
  def prepend(text, content), do: join(text, "\n\n", content)

  @doc """
  Content without its images: the first becomes `text`, after a blank
  line, and the rest go. Content left with text alone is that text.
  """
  @spec leave_out_images(t(), String.t()) :: t()
  def leave_out_images(parts, text) when is_list(parts) do
    {parts, _placed?} =
      Enum.flat_map_reduce(parts, false, fn
        %{"type" => "image_url"}, false -> {[text_part("\n\n" <> text)], true}
        %{"type" => "image_url"}, true -> {[], true}
        part, placed? -> {[part], placed?}
      end)

    case merge(parts) do
      [%{"type" => "text", "text" => only}] -> only
      parts -> parts
    end
  end

  def leave_out_images(content, _text), do: content

  @doc "The bytes of an image part's picture, from its base64."
  @spec bytes(map()) :: non_neg_integer()
  def bytes(%{"image_url" => %{"url" => "data:" <> data}}) do
    case String.split(data, ";base64,", parts: 2) do
      [_type, base64] -> decoded_size(base64)
      _other -> 0
    end
  end

  def bytes(_part), do: 0

  defp decoded_size(base64) do
    padding = byte_size(base64) - byte_size(String.trim_trailing(base64, "="))
    div(byte_size(base64) * 3, 4) - padding
  end

  defp join(a, sep, b) when is_binary(a) and is_binary(b), do: a <> sep <> b
  defp join(a, sep, b), do: merge(parts(a) ++ [text_part(sep)] ++ parts(b))

  @doc "Text and images as one message's content: the text alone when there are none."
  @spec with_images(String.t(), [map()]) :: t()
  def with_images(text, []), do: text
  def with_images(text, images), do: [text_part(text) | images]

  @doc "An image part for a picture's bytes."
  @spec image(String.t(), binary()) :: map()
  def image(mime, data),
    do: %{
      "type" => "image_url",
      "image_url" => %{"url" => "data:#{mime};base64," <> Base.encode64(data)}
    }

  @doc """
  A message with each picture's data replaced by its type and size, for
  the session log: `"omitted: image/png, 2,345 bytes"`.
  """
  @spec omit_images(map()) :: map()
  def omit_images(%{"content" => [_ | _] = parts} = message) do
    parts =
      Enum.map(parts, fn
        %{"type" => "image_url", "image_url" => %{"url" => "data:" <> data}} = part ->
          # A data URL that isn't base64 is still left out, its type unknown.
          omitted =
            case String.split(data, ";base64,", parts: 2) do
              [type, base64] ->
                "omitted: #{type}, #{Visor.Format.number(decoded_size(base64))} bytes"

              _other ->
                "omitted: an image"
            end

          put_in(part, ["image_url", "url"], omitted)

        part ->
          part
      end)

    %{message | "content" => parts}
  end

  def omit_images(message), do: message

  @doc """
  A message read back from a log with each picture it left out as text,
  `[image left out]`, since the provider can't take an omitted one.
  """
  @spec restore_omitted(map()) :: map()
  def restore_omitted(%{"content" => [_ | _] = parts} = message) do
    parts =
      Enum.map(parts, fn
        %{"type" => "image_url", "image_url" => %{"url" => "omitted:" <> _}} ->
          text_part("[image left out]")

        part ->
          part
      end)

    %{message | "content" => merge(parts)}
  end

  def restore_omitted(message), do: message

  @doc "A picture's type from its first bytes: PNG, JPEG, GIF or WebP; nil for anything else."
  @spec mime(binary()) :: String.t() | nil
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
