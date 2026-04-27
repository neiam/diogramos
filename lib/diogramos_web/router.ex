defmodule DiogramosWeb.Router do
  use DiogramosWeb, :router

  import DiogramosWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DiogramosWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  # Same as :browser but relaxes the iframe-blocking headers so the embed
  # route can be loaded inside a third-party page.
  pipeline :browser_embed do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DiogramosWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, %{"x-frame-options" => ""}
    plug :put_embed_csp
    plug :fetch_current_scope_for_user
  end

  defp put_embed_csp(conn, _) do
    Plug.Conn.put_resp_header(conn, "content-security-policy", "frame-ancestors *")
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", DiogramosWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/s/:token", ShareLinkController, :show
    get "/c-embed/:slug", CanvasEmbedRedirectController, :show
  end

  scope "/", DiogramosWeb do
    pipe_through :browser_embed

    live_session :embed, layout: false do
      live "/embed/:token", CanvasLive.Embed, :show
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", DiogramosWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:diogramos, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: DiogramosWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", DiogramosWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{DiogramosWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
      live "/users/invites", UserLive.Invites, :index
      live "/canvases", CanvasLive.Index, :index
      live "/c/:slug", CanvasLive.Edit, :edit
    end

    post "/users/update-password", UserSessionController, :update_password
    get "/c/:slug/export.json", CanvasExportController, :show
  end

  scope "/", DiogramosWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{DiogramosWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
