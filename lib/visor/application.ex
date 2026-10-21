defmodule Visor.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      VisorWeb.Telemetry,
      Visor.Repo,
      {DNSCluster, query: Application.get_env(:visor, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Visor.PubSub},
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
