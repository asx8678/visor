defmodule VisorWeb.ConsoleComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias VisorWeb.ConsoleComponents

  defp markdown(text) do
    assigns = %{text: text}

    ~H"<ConsoleComponents.markdown text={@text} />"
    |> rendered_to_string()
    |> LazyHTML.from_fragment()
  end

  defp text(html, selector), do: html |> LazyHTML.query(selector) |> LazyHTML.text()

  test "renders model Markdown with no stray spaces between inline parts" do
    html =
      markdown("""
      ## Files
      Run `mix test`, then **read** the [docs](https://hexdocs.pm).
      Second line

      - one
        - two
      """)

    assert html |> text("h4") |> String.trim() == "Files"
    assert text(html, "p") == "Run mix test, then read the docs.Second line"
    assert text(html, "p code") == "mix test"
    assert LazyHTML.query(html, "p br") |> Enum.count() == 1
    assert text(html, "ul li > span:last-child") == "onetwo"

    assert html
           |> LazyHTML.query(~s|a[target="_blank"][rel="noopener noreferrer"]|)
           |> LazyHTML.attribute("href") == ["https://hexdocs.pm"]
  end

  test "keeps HTML in model text as text" do
    html =
      markdown("""
      <script>alert(1)</script> and <b>bold</b>
      ```html
      <img src=x onerror=alert(1)>
      ```
      """)

    assert LazyHTML.query(html, "script, b, img") |> Enum.count() == 0
    assert text(html, "p") == "<script>alert(1)</script> and <b>bold</b>"
    assert text(html, "figure pre") == "<img src=x onerror=alert(1)>"
    assert text(html, "figure figcaption span") == "html"
  end
end
