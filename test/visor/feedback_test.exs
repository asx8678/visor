defmodule Visor.FeedbackTest do
  use ExUnit.Case, async: true

  alias Visor.Feedback

  setup do
    id = "feedback-test-#{System.unique_integer([:positive])}"
    start_supervised!({Feedback, id: id})
    %{id: id}
  end

  test "keeps outputs behind refs, the same text under the same ref", %{id: id} do
    assert Feedback.keep(id, "one") == "r1"
    assert Feedback.keep(id, "two") == "r2"
    assert Feedback.keep(id, "one") == "r1"

    assert Feedback.fetch(id, "r2") == {:ok, "two"}
    assert {:error, "There is no output r3." <> _} = Feedback.fetch(id, "r3")
  end

  test "drops the oldest refs past 50 outputs", %{id: id} do
    for n <- 1..51, do: Feedback.keep(id, "output #{n}")

    assert {:error, _} = Feedback.fetch(id, "r1")
    assert Feedback.fetch(id, "r2") == {:ok, "output 2"}
    assert Feedback.fetch(id, "r51") == {:ok, "output 51"}

    # A dropped text gets a new ref.
    assert Feedback.keep(id, "output 1") == "r52"
  end

  test "drops the oldest refs past 20 MB, but always keeps the newest", %{id: id} do
    big = fn byte -> :binary.copy(<<byte>>, 9_000_000) end

    assert Feedback.keep(id, big.(?a)) == "r1"
    assert Feedback.keep(id, big.(?b)) == "r2"
    assert Feedback.keep(id, big.(?c)) == "r3"

    assert {:error, _} = Feedback.fetch(id, "r1")
    assert {:ok, _} = Feedback.fetch(id, "r2")

    assert Feedback.keep(id, :binary.copy("d", 30_000_000)) == "r4"
    assert {:error, _} = Feedback.fetch(id, "r3")
    assert {:ok, _} = Feedback.fetch(id, "r4")
  end

  test "lists changed files and remembers how Mix last saw them", %{id: id} do
    assert Feedback.changed(id, "lib/b.ex", {100, 5}) == {100, 5}
    assert Feedback.changed(id, "lib/a.ex", nil) == nil
    # Only the state before the first change counts.
    assert Feedback.changed(id, "lib/b.ex", {101, 6}) == {100, 5}

    assert Feedback.changed_files(id) == ["lib/a.ex", "lib/b.ex"]

    Feedback.saw(id, %{"lib/b.ex" => {102, 7}})
    assert Feedback.changed(id, "lib/b.ex", {102, 7}) == {102, 7}
  end

  test "returns the previous check of the same scope", %{id: id} do
    assert Feedback.record_check(id, nil, :first) == nil
    assert Feedback.record_check(id, "test/a_test.exs", :scoped) == nil
    assert Feedback.record_check(id, nil, :second) == :first
  end

  test "keeps nothing without a session" do
    assert Feedback.keep(nil, "text") == nil
    assert {:error, "No outputs are kept outside a session."} = Feedback.fetch(nil, "r1")
    assert Feedback.changed(nil, "lib/a.ex", {1, 2}) == {1, 2}
    assert Feedback.changed_files(nil) == []
    assert Feedback.record_check(nil, nil, :check) == nil

    # A session whose collector is gone behaves the same.
    assert Feedback.keep("no-such-session", "text") == nil
  end
end
