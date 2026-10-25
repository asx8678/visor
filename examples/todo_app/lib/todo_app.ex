defmodule TodoApp do
  @moduledoc """
  A to-do list as plain data: items with an id, a title and whether they
  are done. `TodoApp.Store` keeps one in a process.
  """

  defstruct items: [], next_id: 1

  @type item :: %{id: pos_integer(), title: String.t(), done: boolean()}
  @type t :: %__MODULE__{items: [item()], next_id: pos_integer()}

  @doc "An empty list."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Adds an item with `title`, not done yet. Returns the list and the item's id."
  @spec add(t(), String.t()) :: {t(), pos_integer()}
  def add(%__MODULE__{} = list, title) when is_binary(title) do
    id = list.next_id
    item = %{id: id, title: String.trim(title), done: false}
    {%{list | items: list.items ++ [item], next_id: id + 1}, id}
  end

  @doc "Marks item `id` as done."
  @spec complete(t(), pos_integer()) :: t()
  def complete(%__MODULE__{} = list, id) do
    items =
      Enum.map(list.items, fn item ->
        if item.id == id, do: %{item | done: false}, else: item
      end)

    %{list | items: items}
  end

  @doc "The items not done yet, oldest first."
  @spec pending(t()) :: [item()]
  def pending(%__MODULE__{items: items}), do: Enum.reject(items, & &1.done)

  @doc ~S'A one-line summary, such as "2 of 3 done".'
  @spec summary(t()) :: String.t()
  def summary(%__MODULE__{items: items}) do
    "#{Enum.count(items, & &1.done)} of #{length(items)} done"
  end
end
