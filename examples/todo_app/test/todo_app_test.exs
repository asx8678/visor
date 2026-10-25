defmodule TodoAppTest do
  use ExUnit.Case, async: true

  test "adds items, not done yet" do
    {list, 1} = TodoApp.add(TodoApp.new(), " Buy milk ")
    {list, 2} = TodoApp.add(list, "Write report")
    assert [%{title: "Buy milk", done: false}, %{id: 2}] = list.items
    assert TodoApp.summary(list) == "0 of 2 done"
  end

  test "marks an item done" do
    {list, id} = TodoApp.add(TodoApp.new(), "Buy milk")
    {list, _id} = TodoApp.add(list, "Write report")
    list = TodoApp.complete(list, id)
    assert [%{title: "Write report"}] = TodoApp.pending(list)
    assert TodoApp.summary(list) == "1 of 2 done"
  end

  test "keeps a list in a store" do
    {:ok, store} = TodoApp.Store.start_link()
    id = TodoApp.Store.add(store, "Buy milk")
    TodoApp.Store.complete(store, id)
    assert TodoApp.Store.summary(store) == "1 of 1 done"
  end
end
