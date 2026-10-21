defmodule Visor.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # First, so a crash while the rest starts is in the server log.
    Visor.ServerLog.install()

    children = [
      VisorWeb.Telemetry,
      {Phoenix.PubSub, name: Visor.PubSub},
      # Session logs outlive their sessions' last moments, so they stop last.
      {DynamicSupervisor, name: Visor.SessionLogs, strategy: :one_for_one},
      Visor.Harness,
      Visor.Observer,
      # Start to serve requests, typically the last entry
      VisorWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Visor.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    VisorWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
