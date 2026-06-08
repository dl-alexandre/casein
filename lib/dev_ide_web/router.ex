defmodule DevIdeWeb.Router do
  use DevIdeWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DevIdeWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug DevIdeWeb.Plugs.ForwardAuth
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug DevIdeWeb.Plugs.ApiAuth
  end

  scope "/", DevIdeWeb do
    pipe_through :browser

    get "/", PageController, :home

    live "/workspaces", WorkspaceLive.Index, :index
    live "/workspaces/:id", WorkspaceLive.Show, :show
    get "/preview-artifacts/:workspace_id/:filename", PreviewArtifactController, :show
    live "/assignments", AssignmentLive.Index, :index
    live "/assignments/:id", AssignmentLive.Show, :show
    live "/fleet", FleetLive.Index, :index
    live "/fleet/runners/:id", FleetLive.RunnerShow, :show
  end

  scope "/api", DevIdeWeb.API do
    pipe_through :api

    get "/workspaces", WorkspaceController, :index
    get "/workspaces/:id/status", WorkspaceController, :status
    get "/workspaces/:id/topology", WorkspaceController, :topology
    get "/workspaces/:id/templates", WorkspaceController, :templates
    get "/workspaces/:id/templates/export", WorkspaceController, :export_template
    post "/workspaces/:id/templates/export", WorkspaceController, :save_template
    post "/workspaces/:id/templates/:template_id/apply", WorkspaceController, :apply_template
    delete "/workspaces/:id/templates/:template_id", WorkspaceController, :delete_template
    post "/workspaces/:id/windows", WorkspaceController, :create_window
    post "/workspaces/:id/windows/:window_id/select", WorkspaceController, :select_window
    patch "/workspaces/:id/windows/:window_id", WorkspaceController, :rename_window
    delete "/workspaces/:id/windows/:window_id", WorkspaceController, :kill_window
    post "/workspaces/:id/panes", WorkspaceController, :create_pane
    post "/workspaces/:id/panes/:pane_id/select", WorkspaceController, :select_pane
    post "/workspaces/:id/panes/:pane_id/split", WorkspaceController, :split_pane
    post "/workspaces/:id/panes/:pane_id/resize", WorkspaceController, :resize_pane
    delete "/workspaces/:id/panes/:pane_id", WorkspaceController, :kill_pane
    get "/workspaces/:id/runs", WorkspaceController, :runs
    get "/workspaces/:id/runs/:run_id", WorkspaceController, :run
    post "/workspaces/:id/runs", WorkspaceController, :create_run
    get "/workspaces/:id/proposals", WorkspaceController, :proposals
    get "/workspaces/:id/audit", WorkspaceController, :audit

    # Preview-control MCP server: lets external agents (Grok/Claude/Codex/
    # opencode) discover and call DevIDE.Agents.PreviewTools over MCP. Kept on
    # its own route rather than Tidewave's, which has no external-tool hook.
    post "/preview/mcp", PreviewMCPController, :rpc
    get "/preview/mcp", PreviewMCPController, :info

    post "/runner/v1/assignments/poll", RunnerController, :poll
    get "/runner/v1/assignments/:id", RunnerController, :show
    post "/runner/v1/assignments/:id/reports", RunnerController, :report
    post "/runner/v1/assignments/:id/complete", RunnerController, :complete
    post "/runner/v1/assignments/:id/fail", RunnerController, :fail

    post "/fleet/v1/runners/register", FleetRunnerController, :register
    post "/fleet/v1/runners/:runner_id/heartbeat", FleetRunnerController, :heartbeat
    post "/fleet/v1/runners/:runner_id/drain", FleetRunnerController, :drain
    post "/fleet/v1/runners/:runner_id/shutdown", FleetRunnerController, :shutdown
    post "/fleet/v1/runners/:runner_id/offers/poll", FleetRunnerController, :poll_offer
    post "/fleet/v1/messages", FleetRunnerController, :message
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:dev_ide, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: DevIdeWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
