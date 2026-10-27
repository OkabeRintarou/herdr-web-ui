defmodule HerdrLiveViewWeb.Router do
  use HerdrLiveViewWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {HerdrLiveViewWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug HerdrLiveViewWeb.Auth
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", HerdrLiveViewWeb do
    pipe_through :browser

    live_session :default, on_mount: {HerdrLiveViewWeb.Auth, :require_auth} do
      live "/", DashboardLive, :index
      live "/panes/:pane_id", DashboardLive, :show
      live "/tasks", TaskBoardLive, :index
      live "/tasks/new", TaskBoardLive, :new
      live "/tasks/:id", TaskBoardLive, :show
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", HerdrLiveViewWeb do
  #   pipe_through :api
  # end
end
