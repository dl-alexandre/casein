defmodule DevIdeWeb.Router do
  use DevIdeWeb, :router

  # Content-Security-Policy for the cockpit UI.
  #
  # - `script-src` allows same-origin scripts plus the sha256 hash of the one
  #   inline script we ship: the theme bootstrap in root.html.heex. If you
  #   edit that script, recompute the hash:
  #     python3 -c "import hashlib,base64,re,sys; s=open('lib/dev_ide_web/components/layouts/root.html.heex').read(); print('sha256-'+base64.b64encode(hashlib.sha256(re.search(r'<script>(.*?)</script>',s,re.S).group(1).encode()).digest()).decode())"
  #   In dev we fall back to 'unsafe-inline' because LiveDashboard injects its
  #   own inline scripts (and browsers ignore 'unsafe-inline' when a hash is
  #   present, so we cannot ship both).
  # - `connect-src ws: wss:` covers the LiveView socket and terminal channel.
  # - `img-src data: blob:` covers dropped/pasted terminal images.
  # - `frame-src 'none'` keeps previews out of browser-managed child frames;
  #   the cockpit renders agent observations and provides a user-clicked link
  #   for the live app.
  @script_src if Application.compile_env(:dev_ide, :dev_routes),
                do: "script-src 'self' 'unsafe-inline'",
                else: "script-src 'self' 'sha256-ZSLtwbmogvdRQWylw6MDGKCK+VIz+hyMBvfpcdn8AQs='"

  @content_security_policy [
                             "default-src 'self'",
                             @script_src,
                             "style-src 'self' 'unsafe-inline'",
                             "img-src 'self' data: blob:",
                             "connect-src 'self' ws: wss:",
                             "frame-src 'none'",
                             "object-src 'none'",
                             "base-uri 'self'",
                             "frame-ancestors 'self'"
                           ]
                           |> Enum.join("; ")

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DevIdeWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, %{"content-security-policy" => @content_security_policy}
    plug DevIdeWeb.Plugs.ForwardAuth
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug DevIdeWeb.Plugs.ApiAuth
  end

  pipeline :mcp_api do
    plug :accepts, ["json"]
    plug DevIdeWeb.Plugs.ApiAuth
    plug DevIdeWeb.Plugs.McpRateLimit
  end

  scope "/", DevIdeWeb do
    pipe_through :browser

    get "/", PageController, :home

    live_session :default, on_mount: [{DevIdeWeb.DeploymentUpdateHook, :default}] do
      live "/workspaces", WorkspaceLive.Index, :index
      live "/workspaces/:id", WorkspaceLive.Show, :show
      live "/assignments", AssignmentLive.Index, :index
      live "/assignments/:id", AssignmentLive.Show, :show
      live "/fleet", FleetLive.Index, :index
      live "/fleet/runners/:id", FleetLive.RunnerShow, :show
    end

    get "/preview-artifacts/:workspace_id/:filename", PreviewArtifactController, :show
  end

  scope "/api", DevIdeWeb.API do
    pipe_through :api

    get "/workspaces", WorkspaceController, :index
    get "/workspaces/:id/status", WorkspaceController, :status
    get "/workspaces/:id/topology", WorkspaceController, :topology
    get "/workspaces/:id/runs", WorkspaceController, :runs
    get "/workspaces/:id/runs/:run_id", WorkspaceController, :run
    post "/workspaces/:id/runs", WorkspaceController, :create_run
    get "/workspaces/:id/proposals", WorkspaceController, :proposals
    get "/workspaces/:id/audit", WorkspaceController, :audit

    get "/workspaces/:id/templates", WorkspaceTemplateController, :templates
    get "/workspaces/:id/templates/export", WorkspaceTemplateController, :export_template
    post "/workspaces/:id/templates/export", WorkspaceTemplateController, :save_template

    patch "/workspaces/:id/templates/:template_id",
          WorkspaceTemplateController,
          :update_template

    post "/workspaces/:id/templates/:template_id/duplicate",
         WorkspaceTemplateController,
         :duplicate_template

    post "/workspaces/:id/templates/:template_id/apply",
         WorkspaceTemplateController,
         :apply_template

    delete "/workspaces/:id/templates/:template_id",
           WorkspaceTemplateController,
           :delete_template

    post "/workspaces/:id/windows", WorkspaceWindowController, :create_window
    post "/workspaces/:id/windows/:window_id/select", WorkspaceWindowController, :select_window
    patch "/workspaces/:id/windows/:window_id", WorkspaceWindowController, :rename_window
    delete "/workspaces/:id/windows/:window_id", WorkspaceWindowController, :kill_window

    post "/workspaces/:id/panes", WorkspacePaneController, :create_pane
    post "/workspaces/:id/panes/:pane_id/select", WorkspacePaneController, :select_pane
    post "/workspaces/:id/panes/:pane_id/split", WorkspacePaneController, :split_pane
    post "/workspaces/:id/panes/:pane_id/resize", WorkspacePaneController, :resize_pane
    delete "/workspaces/:id/panes/:pane_id", WorkspacePaneController, :kill_pane

    post "/preview/panes", PreviewPaneController, :create
    delete "/preview/panes/:id", PreviewPaneController, :delete

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

    get "/deploy_status", DeployStatusController, :show
    post "/drain", DrainController, :drain
  end

  scope "/api", DevIdeWeb.API do
    pipe_through :mcp_api

    # Preview-control MCP server: lets external agents (Grok/Claude/Codex/
    # opencode) discover and call DevIDE.Agents.PreviewTools over MCP. Kept on
    # its own route rather than Tidewave's, which has no external-tool hook.
    post "/preview/mcp", PreviewMCPController, :rpc
    get "/preview/mcp", PreviewMCPController, :info

    # Terminal-control MCP server: lets external agents discover DevIDE tmux
    # sessions and read panes / send keys, mirroring PreviewMCP's transport.
    post "/terminals/mcp", TerminalMCPController, :rpc
    get "/terminals/mcp", TerminalMCPController, :info
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
