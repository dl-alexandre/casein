defmodule DevIdeWeb.Router do
  @moduledoc """
  HTTP/LiveView/MCP route table and request pipelines (`:browser`,
  `:preview_proxy`, `:api`, `:mcp_api`) for the DevIDE cockpit, including the
  cockpit UI, preview proxy/artifacts, the read-only workspace API, the deploy
  drain/status endpoints, and the agent-facing terminal/preview/artifact MCP
  routes.
  """
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
  # - `frame-src` admits preview-pane iframes. Runtime deployments can override
  #   this through `:dev_ide, :preview_frame_src`.
  @script_src if Application.compile_env(:dev_ide, :dev_routes),
                do: "script-src 'self' 'unsafe-inline'",
                else: "script-src 'self' 'sha256-ZSLtwbmogvdRQWylw6MDGKCK+VIz+hyMBvfpcdn8AQs='"

  @default_frame_src "frame-src * data: blob:"

  @content_security_policy_base [
                                  "default-src 'self'",
                                  @script_src,
                                  "style-src 'self' 'unsafe-inline'",
                                  "img-src 'self' data: blob:",
                                  "connect-src 'self' ws: wss:",
                                  "object-src 'none'",
                                  "base-uri 'self'",
                                  "frame-ancestors 'self'"
                                ]
                                |> Enum.join("; ")

  defp put_content_security_policy(conn, _opts) do
    frame_src = Application.get_env(:dev_ide, :preview_frame_src, @default_frame_src)

    Plug.Conn.put_resp_header(
      conn,
      "content-security-policy",
      @content_security_policy_base <> "; " <> frame_src
    )
  end

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DevIdeWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers,
         %{
           "content-security-policy" =>
             @content_security_policy_base <> "; " <> @default_frame_src
         }

    plug :put_content_security_policy
    plug DevIdeWeb.Plugs.ForwardAuth
  end

  # Preview reverse proxy. Deliberately omits the cockpit's secure-browser
  # headers and CSP: the proxy re-serves arbitrary workspace app HTML, which
  # must run under its own (relaxed) framing rules, not `default-src 'self'`.
  # Session + ForwardAuth still establish and authorize the viewer.
  # The proxy also forwards non-GET dev-app traffic such as Phoenix long-poll
  # transport requests; workspace ownership, allowed-port checks, and a fixed
  # 127.0.0.1 upstream keep it from becoming a general-purpose proxy.
  pipeline :preview_proxy do
    plug :fetch_session
    plug DevIdeWeb.Plugs.ForwardAuth
  end

  # Browser-authenticated workspace file bytes for rendered Markdown. This is
  # GET-only and intentionally omits the cockpit CSP because responses are raw
  # file bytes, not app HTML.
  pipeline :workspace_file do
    plug :fetch_session
    plug :protect_from_forgery
    plug DevIdeWeb.Plugs.ForwardAuth
  end

  # Client-streamed preview recordings. Raw octet-stream chunk bodies pass
  # through the global Plug.Parsers (`pass: ["*/*"]`) unparsed, so the controller
  # reads them via read_body. CSRF is enforced (the browser sends the page's
  # x-csrf-token header); ForwardAuth + the controller authorize workspace
  # ownership per request.
  pipeline :api do
    plug :accepts, ["json"]
    plug DevIdeWeb.Plugs.ApiAuth
  end

  pipeline :device_link_api do
    plug :accepts, ["json"]
  end

  pipeline :mcp_api do
    plug :accepts, ["json"]
    plug DevIdeWeb.Plugs.ApiAuth
    plug DevIdeWeb.Plugs.McpRateLimit
  end

  # GitHub push webhook — authenticated via X-Hub-Signature-256, not ApiAuth.
  pipeline :deploy_webhook do
    plug :accepts, ["json"]
    plug DevIdeWeb.Plugs.DeployWebhookAuth
  end

  # Streamable HTTP transport (GET SSE channel + DELETE session teardown). No
  # strict :accepts — SSE clients send `Accept: text/event-stream` only.
  pipeline :mcp_stream do
    plug DevIdeWeb.Plugs.ApiAuth
    plug DevIdeWeb.Plugs.McpRateLimit
  end

  scope "/", DevIdeWeb do
    pipe_through :browser

    live_session :default,
      on_mount: [
        {DevIdeWeb.AssignCurrentUserHook, :default},
        {DevIdeWeb.DeploymentUpdateHook, :default}
      ] do
      # Root lands in the cockpit on the workspaceless scratch PTY ($HOME).
      # Dir browse is the SESSIONS Browse tier (Stage 4b). No separate
      # full-page dashboard or workspace-admin drawer.
      live "/", WorkspaceLive.Show, :root
      live "/workspaces/:id", WorkspaceLive.Show, :show
    end

    # Legacy picker URL — redirects to scratch cockpit at "/".
    get "/workspaces", LegacyWorkspaceController, :index

    # Notifications page absorbed by the in-viewer notifications drawer
    # (?drawer=notifications on the cockpit).
    get "/notifications", LegacyWorkspaceController, :notifications

    # Previous-sessions page absorbed by the cockpit History panel (?tab=history).
    get "/workspaces/:id/previous-sessions", LegacyWorkspaceController, :previous_sessions

    get "/preview-artifacts/:workspace_id/:filename", PreviewArtifactController, :show

    # Mobile companion pairing — QR + credentials for DevideMob.SessionClient.
    get "/pair/:workspace_id", PairingController, :show
  end

  scope "/preview-proxy", DevIdeWeb do
    pipe_through :preview_proxy

    match :*, "/:workspace_id/:port/*path", PreviewProxyController, :proxy
  end

  # Durable, login-gated public URL for an artifact project's static files,
  # served straight from its git worktree (not the ephemeral loopback preview
  # server). Uses :workspace_file (session + ForwardAuth, no cockpit CSP — the
  # controller sets its own tight CSP for workspace-authored content) and gates
  # on workspace ownership. This is the PR-shareable artifact link.
  scope "/artifact-projects", DevIdeWeb do
    pipe_through :workspace_file

    get "/:workspace_id/:artifact_project_id/*path", ArtifactProjectController, :show
  end

  scope "/api", DevIdeWeb do
    pipe_through :workspace_file

    get "/workspaces/:id/files/*path", WorkspaceFileController, :show
  end

  scope "/api", DevIdeWeb.API do
    pipe_through :device_link_api

    post "/device-links/exchange", DeviceLinkController, :exchange
    post "/device-links/rotate", DeviceLinkController, :rotate
    post "/device-links/revoke", DeviceLinkController, :revoke
  end

  scope "/api", DevIdeWeb.API do
    pipe_through :api

    get "/workspaces", WorkspaceController, :index
    get "/workspaces/:id/status", WorkspaceController, :status
    get "/workspaces/:id/topology", WorkspaceController, :topology
    get "/workspaces/:id/runs", WorkspaceController, :runs
    get "/workspaces/:id/runs/:run_id", WorkspaceController, :run
    get "/workspaces/:id/proposals", WorkspaceController, :proposals
    get "/workspaces/:id/audit", WorkspaceController, :audit
    get "/workspaces/:id/previous_sessions", WorkspaceController, :previous_sessions

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

    get "/deploy_status", DeployStatusController, :show
    get "/smoke/terminal", TerminalSmokeController, :show
    post "/drain", DrainController, :drain
  end

  scope "/api", DevIdeWeb.API do
    pipe_through :deploy_webhook

    post "/deploy_webhook", DeployWebhookController, :github
  end

  scope "/api", DevIdeWeb.API do
    pipe_through :mcp_api

    post "/workspaces/:id/open", WorkspaceOpenController, :open

    # Preview-control MCP server: lets external agents (Grok/Claude/Codex/
    # opencode) discover and call DevIDE.Agents.PreviewTools over MCP. Kept on
    # its own route rather than Tidewave's, which has no external-tool hook.
    post "/preview/mcp", PreviewMCPController, :rpc

    # Terminal-control MCP server: lets external agents discover DevIDE tmux
    # sessions and read panes / send keys, mirroring PreviewMCP's transport.
    post "/terminals/mcp", TerminalMCPController, :rpc

    # Artifact-project MCP server: lets external agents create and iterate on
    # Git worktree-backed artifacts, returning Preview MCP handoff arguments.
    post "/artifacts/mcp", ArtifactMCPController, :rpc
  end

  # Streamable HTTP: server→client SSE channel (GET) and session teardown
  # (DELETE), keyed by the Mcp-Session-Id issued on initialize.
  scope "/api", DevIdeWeb.API do
    pipe_through :mcp_stream

    get "/preview/mcp", PreviewMCPController, :info
    delete "/preview/mcp", PreviewMCPController, :delete
    get "/terminals/mcp", TerminalMCPController, :info
    delete "/terminals/mcp", TerminalMCPController, :delete
    get "/artifacts/mcp", ArtifactMCPController, :info
    delete "/artifacts/mcp", ArtifactMCPController, :delete
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

  scope "/", DevIdeWeb do
    pipe_through :browser

    live_session :path_workspaces,
      on_mount: [
        {DevIdeWeb.AssignCurrentUserHook, :default},
        {DevIdeWeb.DeploymentUpdateHook, :default}
      ] do
      live "/*lan_path", WorkspaceLive.Show, :lan_path
    end
  end
end
