defmodule TodoApp.Store do
  @moduledoc "A to-do list kept in a process, for the parts of an app that share one."
  use Agent

  @doc "Starts a store with an empty list."
  def start_link(opts \\ []), do: Agent.start_link(&TodoApp.new/0, opts)

  @doc "Adds an item with `title`. Returns its id."
  def add(store, title) do
    Agent.get_and_update(store, fn list ->
      {list, id} = TodoApp.add(list, title)
      {id, list}
    end)
  end

  @doc "Marks item `id` as done."
  def complete(store, id), do: Agent.update(store, &TodoApp.complete(&1, id))

  @doc "The list's summary (`TodoApp.summary/1`)."
  def summary(store), do: Agent.get(store, &TodoApp.summary/1)
end
