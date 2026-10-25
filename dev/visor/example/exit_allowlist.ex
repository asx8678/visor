defmodule Visor.Example.ExitAllowlist do
  @moduledoc """
  The scripts' allowlist (`Visor.Code.Allowlist`) and
  `Visor.Example.Exits.exit_with/1`, for `mix visor.example`.
  """
  use Dune.Allowlist, extend: Visor.Code.Allowlist

  allow Visor.Example.Exits, only: [:exit_with]
end
