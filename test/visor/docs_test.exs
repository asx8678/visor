defmodule Visor.DocsTest do
  # V.docs and V.source read the project's compiled code, as Tidewave's
  # get_docs and get_source_location do, without loading it.
  use ExUnit.Case, async: false

  alias Visor.Docs

  @moduletag :tmp_dir

  @source """
  defmodule VisorDocsDemo do
    @moduledoc "A demo of what V.docs reads."

    @doc "Adds `b` to `a`."
    def add(a, b \\\\ 1), do: a + b

    def bare, do: hidden(:ok)

    defp hidden(x), do: x
  end
  """

  # A project with the module compiled where Mix puts it, from its source
  # in the project. The module is unloaded after, so the next test's
  # compile doesn't redefine it.
  setup %{tmp_dir: dir} do
    previous = Application.get_env(:visor, :workspace)
    Application.put_env(:visor, :workspace, dir)
    on_exit(fn -> Application.put_env(:visor, :workspace, previous) end)

    source = Path.join(dir, "lib/docs_demo.ex")
    File.mkdir_p!(Path.dirname(source))
    File.write!(source, @source)

    docs = Code.get_compiler_option(:docs)
    Code.put_compiler_option(:docs, true)
    [{VisorDocsDemo, beam}] = Code.compile_string(@source, source)
    Code.put_compiler_option(:docs, docs)

    on_exit(fn ->
      :code.purge(VisorDocsDemo)
      :code.delete(VisorDocsDemo)
    end)

    ebin = Path.join(dir, "_build/dev/lib/docs_demo/ebin")
    File.mkdir_p!(ebin)
    File.write!(Path.join(ebin, "Elixir.VisorDocsDemo.beam"), beam)
    :ok
  end

  test "gives a function's signatures and doc, and a module's summary" do
    assert {:ok, text} = Docs.docs("VisorDocsDemo.add/2")
    assert text =~ "VisorDocsDemo.add/2\n\nadd(a, b \\\\ 1)\n\nAdds `b` to `a`."
    # A default argument's shorter arity is the same function.
    assert {:ok, ^text} = Docs.docs("VisorDocsDemo.add/1")

    assert {:ok, summary} = Docs.docs("VisorDocsDemo")
    assert summary =~ "A demo of what V.docs reads."
    assert summary =~ "  add(a, b \\\\ 1): Adds `b` to `a`"
    assert summary =~ "  bare()"
    refute summary =~ "hidden"

    assert {:ok, enum} = Docs.docs("Enum.map/2")
    assert enum =~ "map(enumerable, fun)"
  end

  test "says where a module or function is, private ones too, and a dependency's folder",
       %{tmp_dir: dir} do
    assert {:ok, %{file: "lib/docs_demo.ex", line: 5}} = Docs.source("VisorDocsDemo.add")
    assert {:ok, %{file: "lib/docs_demo.ex", line: 7}} = Docs.source("VisorDocsDemo.bare/0")
    assert {:ok, %{file: "lib/docs_demo.ex", line: 9}} = Docs.source("VisorDocsDemo.hidden")
    assert {:ok, %{file: "lib/docs_demo.ex"}} = Docs.source("VisorDocsDemo")

    File.mkdir_p!(Path.join(dir, "deps/demo_dep"))
    assert {:ok, %{file: "deps/demo_dep"}} = Docs.source("dep:demo_dep")
    assert {:error, "There is no dependency nope in deps/."} = Docs.source("dep:nope")
  end

  test "explains what it can't find, and is a V call" do
    assert {:error, "There is no compiled module Nope in the project" <> _} = Docs.docs("Nope.x")
    assert {:error, ~s|"no way" isn't a reference| <> _} = Docs.docs("no way")

    assert {:ok, "VisorDocsDemo has no documented function nothing."} =
             Docs.docs("VisorDocsDemo.nothing")

    assert {:ok, text} = Visor.Code.run(~S|V.source("VisorDocsDemo.add/2")|, %{})
    assert text =~ ~s(=> %{file: "lib/docs_demo.ex", line: 5})
  end
end
