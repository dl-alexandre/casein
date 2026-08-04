defmodule CaseinWeb.PreviewAuthzControllerTest do
  @moduledoc """
  The forward-auth sub-request the edge router makes before proxying an
  own-origin preview host to a loopback port.

  The decision is derived from the request's own hostname, so these drive the
  endpoint the way Caddy does: same URI every time, only the Host varies.
  """
  use CaseinWeb.ConnCase, async: false

  alias Casein.Previews.OwnOrigin

  @workspace "37a50042-54ca-4a6b-9f89-aa21ae5bf623"
  @domain "devbox.milcgroup.com"

  defmodule StubSource do
    @moduledoc false
    @behaviour Casein.WorkspaceSource

    @impl true
    def get(id, _auth) do
      {:ok, %Casein.Workspace{id: id, name: "stub", user: "dalexandre", status: :running}}
    end

    @impl true
    def list(_opts, _auth), do: {:ok, []}
    @impl true
    def create(_params, _auth), do: {:error, :unsupported}
    @impl true
    def start(_id, _auth), do: {:error, :unsupported}
    @impl true
    def stop(_id, _auth), do: {:error, :unsupported}
    @impl true
    def delete(_id, _opts, _auth), do: {:error, :unsupported}
    @impl true
    def stream_logs(_id, _service, _pid), do: {:error, :unsupported}
    @impl true
    def safe_host_path(_workspace), do: {:error, :unsupported}
    @impl true
    def safe_host_loc(_workspace), do: {:error, :unsupported}
    @impl true
    def prepare_local_argv(argv), do: argv
    @impl true
    def prepare_local_argv(argv, _opts), do: argv
    @impl true
    def local_tmux_pane_shell, do: nil
    @impl true
    def local_tmux_pane_shell(_host_cwd), do: nil
    @impl true
    def local_exec_cwd(host_cwd), do: host_cwd
    @impl true
    def default_log_service(_workspace), do: nil
    @impl true
    def detect_capabilities(_workspace, _root), do: []
    @impl true
    def create_form_fields, do: []
  end

  setup do
    prev = %{
      source: Application.get_env(:casein, :workspace_source),
      forward_auth: Application.get_env(:casein, :forward_auth),
      own_origin: Application.get_env(:casein, :preview_own_origin)
    }

    Casein.PreviewPanes.clear()
    Application.put_env(:casein, :workspace_source, StubSource)
    Application.put_env(:casein, :forward_auth, true)
    Application.put_env(:casein, :preview_own_origin, enabled: true, domain: @domain)

    on_exit(fn ->
      Casein.PreviewPanes.clear()
      restore(:workspace_source, prev.source)
      restore(:forward_auth, prev.forward_auth)
      restore(:preview_own_origin, prev.own_origin)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, val), do: Application.put_env(:casein, key, val)

  # Mirrors the router: authenticated identity in the forward-auth header, the
  # preview hostname as Host, and a fixed authz URI.
  defp authz(conn, host, opts \\ []) do
    conn
    |> Plug.Conn.put_req_header("x-auth-request-email", opts[:email] || "dalexandre@example.com")
    |> then(fn c ->
      if host, do: Plug.Conn.put_req_header(c, "x-forwarded-host", host), else: c
    end)
    |> get("/api/previews/authz")
  end

  defp register_preview_port!(workspace_id, port) do
    pane_id = "%preview-authz-#{System.unique_integer([:positive])}"

    assert {:ok, _registration} =
             Casein.PreviewPanes.register(%{
               "pane_id" => pane_id,
               "url" => "http://127.0.0.1:#{port}/",
               "workspace_id" => workspace_id
             })

    port
  end

  test "allows a port this workspace has published", %{conn: conn} do
    port = register_preview_port!(@workspace, 21_005)
    {:ok, host} = OwnOrigin.host(@workspace, port)

    assert conn |> authz(host) |> response(204) == ""
  end

  # The whole point of the second forward-auth hop: being signed in is not
  # enough, or any employee could reach any workspace's dev server.
  test "denies a port the workspace has not published", %{conn: conn} do
    register_preview_port!(@workspace, 21_005)
    {:ok, host} = OwnOrigin.host(@workspace, 4003)

    assert conn |> authz(host) |> response(403) == ""
  end

  test "denies an unauthenticated request", %{conn: conn} do
    port = register_preview_port!(@workspace, 21_005)
    {:ok, host} = OwnOrigin.host(@workspace, port)

    assert conn
           |> put_req_header("x-forwarded-host", host)
           |> get("/api/previews/authz")
           |> response(401)
  end

  test "denies a host that is not a preview host", %{conn: conn} do
    register_preview_port!(@workspace, 21_005)

    assert conn |> authz("casein.#{@domain}") |> response(403) == ""
    assert conn |> authz("pv-21005.#{@domain}") |> response(403) == ""
    assert conn |> authz("pv-notaport-#{@workspace}.#{@domain}") |> response(403) == ""
  end

  # A registration belonging to a different workspace must not authorize this
  # one, even though both are reachable by the same authenticated viewer.
  test "denies a port published by a different workspace", %{conn: conn} do
    other = "d4001a09-524d-4555-8e4a-5e65b8fdc271"
    register_preview_port!(other, 4003)
    {:ok, host} = OwnOrigin.host(@workspace, 4003)

    assert conn |> authz(host) |> response(403) == ""
  end

  test "still authorizes after own-origin routing is switched off", %{conn: conn} do
    port = register_preview_port!(@workspace, 21_005)
    {:ok, host} = OwnOrigin.host(@workspace, port)
    Application.put_env(:casein, :preview_own_origin, enabled: false, domain: @domain)

    assert conn |> authz(host) |> response(204) == ""
  end
end
