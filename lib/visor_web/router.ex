defmodule VisorWeb.Router do
  use VisorWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {VisorWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", VisorWeb do
    pipe_through :browser

    live_session :harness, session: {VisorWeb.ClientLayout, :session, []} do
      live "/", HarnessLive
    end
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:visor, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: VisorWeb.Telemetry
    end
  end
end
