defmodule HashClusterWeb.Router do
  use HashClusterWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {HashClusterWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", HashClusterWeb do
    pipe_through :browser

    live "/", DashboardLive, :index
  end
end
