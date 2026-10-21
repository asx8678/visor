defmodule Visor.Repo do
  use Ecto.Repo,
    otp_app: :visor,
    adapter: Ecto.Adapters.Postgres
end
