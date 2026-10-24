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
end
