defmodule Visor.MemoryTest do
  # Vibe's curated memory: notes a project keeps for its later sessions.
  use ExUnit.Case, async: false

  alias Visor.{Code, Memory}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:visor, :workspace)
    Application.put_env(:visor, :workspace, dir)
    on_exit(fn -> Application.put_env(:visor, :workspace, previous) end)
    %{dir: dir}
  end

  test "keeps notes once each, within bounds, where scripts can't write", %{dir: dir} do
    assert {:ok, ["Use tabs."]} = Memory.remember("  Use\ntabs.  ")
    assert {:ok, ["Use tabs."]} = Memory.remember("Use tabs.")
    slow = "Run the slow tests with --include slow."
    assert {:ok, ["Use tabs.", ^slow]} = Memory.remember(slow)
    assert File.read!(Path.join(dir, ".visor/memory.md")) == "- Use tabs.\n- #{slow}\n"

    assert {:error, "A note is at most 300 characters."} =
             Memory.remember(String.duplicate("x", 301))

    assert {:ok, [^slow]} = Memory.forget("Use tabs.")
    assert {:error, "There is no note \"nope\"" <> _} = Memory.forget("nope")

    assert {:error, _refused} = Code.run(~S|V.write(".visor/memory.md", "- injected\n")|, %{})
    assert Memory.list() == [slow]
  end

  test "puts the notes in a later session's system prompt, and reads them through V" do
    {:ok, _notes} = Memory.remember("The API is versioned under /v2.")
    id = "memory#{System.unique_integer([:positive])}"
    start_supervised!({Visor.Harness.Session, id: id, owner: self()})
    agent = GenServer.whereis(Visor.Harness.via({id, :agent}))

    assert :sys.get_state(agent).system =~
             "What earlier sessions on this project asked to remember (V.remember):\n" <>
               "- The API is versioned under /v2."

    assert {:ok, text} = Code.run(~S|V.memories()|, %{session: id, call_id: "c1"})
    assert text =~ "The API is versioned under /v2."
  end
end
