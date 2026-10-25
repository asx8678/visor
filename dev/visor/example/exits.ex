defmodule Visor.Example.Exits do
  @moduledoc """
  A function that exits, for `mix visor.example` to check what the
  sandbox does when a call it allows exits with a reason that isn't an
  exception's, as a `V` call's `Task.await` or call to a process that is
  gone can (`Visor.Example.ExitAllowlist`).
  """

  @doc "Exits with `reason`."
  def exit_with(reason), do: exit(reason)
end
