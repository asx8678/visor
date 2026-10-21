defmodule VisorWeb.MarkdownTest do
  use ExUnit.Case, async: true

  import VisorWeb.Markdown

  test "reads the lists, bold and code paths a model writes" do
    text = """
    **test/**
    - `test_helper.exs`
    - `test/visor/` — `agent_test.exs`, `feedback/`
      and more

    It's a Phoenix app named **Visor**, an *agent* harness.
    """

    assert parse(text) == [
             {:paragraph, [{:strong, ["test/"]}]},
             {:list,
              [
                {"•", 0, [{:code, "test_helper.exs"}]},
                {"•", 0,
                 [
                   {:code, "test/visor/"},
                   " — ",
                   {:code, "agent_test.exs"},
                   ", ",
                   {:code, "feedback/"},
                   " and more"
                 ]}
              ]},
             {:paragraph,
              [
                "It's a Phoenix app named ",
                {:strong, ["Visor"]},
                ", an ",
                {:em, ["agent"]},
                " harness."
              ]}
           ]
  end

  test "keeps numbers, depth, headings, quotes, rules and tables" do
    text = """
    ## Next steps ##
    1. Read `README.md`
    2) Run the tests
       - with `V.check()`

    > Quoted *text*
    ---
    | File | Lines |
    |------|------:|
    | `a.ex` | 12 |
    after the table
    """

    assert parse(text) == [
             {:heading, 2, ["Next steps"]},
             {:list,
              [
                {"1.", 0, ["Read ", {:code, "README.md"}]},
                {"2.", 0, ["Run the tests"]},
                {"•", 1, ["with ", {:code, "V.check()"}]}
              ]},
             {:quote, [{:paragraph, ["Quoted ", {:em, ["text"]}]}]},
             :rule,
             {:table, [["File"], ["Lines"]], [[[{:code, "a.ex"}], ["12"]]]},
             {:paragraph, ["after the table"]}
           ]
  end

  test "parses replies cut off while they stream in" do
    assert parse("Here:\n```elixir\nIO.puts(1)\n") == [
             {:paragraph, ["Here:"]},
             {:code, "elixir", "IO.puts(1)\n"}
           ]

    assert parse("```\na\n```\nafter") == [{:code, "", "a"}, {:paragraph, ["after"]}]
    assert parse("Half **bold") == [{:paragraph, ["Half **bold"]}]
    assert parse("Half `code") == [{:paragraph, ["Half `code"]}]
    assert parse("| a |\n") == [{:paragraph, ["| a |"]}]
    assert parse("- ") == [{:paragraph, ["-"]}]
    assert parse("") == []
  end

  test "links only http and https, and leaves snake_case alone" do
    assert inline("[docs](https://hexdocs.pm/req), https://example.com/a_b.") == [
             {:link, "https://hexdocs.pm/req", ["docs"]},
             ", ",
             {:link, "https://example.com/a_b", ["https://example.com/a_b"]},
             "."
           ]

    assert inline("[x](javascript:alert(1)) prompt_cache_hit_tokens and _em_") == [
             "[x](javascript:alert(1)) prompt_cache_hit_tokens and ",
             {:em, ["em"]}
           ]
  end
end
