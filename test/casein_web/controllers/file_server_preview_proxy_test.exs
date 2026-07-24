defmodule CaseinWeb.FileServerPreviewProxyTest do
  @moduledoc """
  Runtime verification that terminal file-link previews work end-to-end:

    FileServer (ephemeral 127.0.0.1 port)
      → PreviewPanes registration (registered_preview_port? escape hatch)
      → PreviewProxyController GET /preview-proxy/WSID/PORT/FILE
      → 200 + BrowserViewable content-type

  This is the plan's "Route A" evidence without a full headless viewer walk.
  """
  use CaseinWeb.ConnCase, async: false

  alias Casein.Files.BrowserViewable
  alias Casein.PreviewPanes
  alias Casein.Previews
  alias Casein.Previews.FileServer
  alias Casein.Workspaces

  setup do
    prev_root = Application.get_env(:casein, :workspaces_root)
    prev_source = Application.get_env(:casein, :workspace_source)
    prev_forward_auth = Application.get_env(:casein, :forward_auth)
    prev_idle = Application.get_env(:casein, :file_server_idle_ms)
    prev_persistence = Application.get_env(:casein, :preview_pane_persistence_enabled)

    PreviewPanes.clear()
    Application.put_env(:casein, :preview_pane_persistence_enabled, false)
    Application.put_env(:casein, :file_server_idle_ms, 60_000)

    on_exit(fn ->
      PreviewPanes.clear()
      restore(:workspaces_root, prev_root)
      restore(:workspace_source, prev_source)
      restore(:forward_auth, prev_forward_auth)
      restore(:file_server_idle_ms, prev_idle)
      restore(:preview_pane_persistence_enabled, prev_persistence)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, val), do: Application.put_env(:casein, key, val)

  defp seed_workspace! do
    root = Path.join(System.tmp_dir!(), "fs-proxy-#{System.unique_integer([:positive])}")
    # owner_from_path → first segment under workspaces_root → "dev"
    path = Path.join([root, "dev", "ws"])
    File.mkdir_p!(path)
    Application.put_env(:casein, :workspaces_root, root)
    Application.put_env(:casein, :workspace_source, Casein.WorkspaceSource.Local)
    Application.put_env(:casein, :forward_auth, true)

    {:ok, workspace} = Workspaces.attach_folder(path)
    {root, path, workspace}
  end

  defp auth_get(conn, path) do
    conn
    |> put_req_header("x-auth-request-email", "dev@local")
    |> get(path)
  end

  defp content_type(conn) do
    case get_resp_header(conn, "content-type") do
      [value | _] -> value
      _ -> nil
    end
  end

  test "FileServer port is admitted only via registered_preview_port? and serves html/png through the proxy",
       %{conn: conn} do
    {root, ws_path, workspace} = seed_workspace!()
    on_exit(fn -> FileServer.stop(workspace) end)

    png_bytes = <<137, 80, 78, 71, 13, 10, 26, 10, "png-payload">>
    html_body = "<!doctype html><html><body><h1>file-server-report</h1></body></html>\n"
    File.write!(Path.join(ws_path, "shot.png"), png_bytes)
    File.write!(Path.join(ws_path, "report.html"), html_body)

    # (a) ephemeral loopback listener
    assert {:ok, port} = FileServer.ensure_started(workspace)
    assert is_integer(port) and port > 0 and port < 65_536
    # Ephemeral ports are almost never in the common-dev allowlist; if one is,
    # re-bind by stopping and starting again is unnecessary — assert the
    # registration path is still required by clearing panes first.
    refute Previews.port_allowed?(port, workspace),
           "expected ephemeral FileServer port #{port} to need registered_preview_port?"

    # Without a pane registration the proxy refuses the port.
    denied =
      auth_get(conn, "/preview-proxy/#{workspace.id}/#{port}/shot.png")

    assert response(denied, 403) =~ "Port not allowed"

    # (b) registration admits the port (same escape hatch open_link_in_preview uses)
    pane_id = "%fs-proxy-#{System.unique_integer([:positive])}"
    file_url = "http://127.0.0.1:#{port}/shot.png"

    assert {:ok, reg} =
             PreviewPanes.register(%{
               "pane_id" => pane_id,
               "url" => file_url,
               "workspace_id" => workspace.id
             })

    assert reg.url =~ "#{port}"
    assert Enum.any?(PreviewPanes.list_for_workspace(workspace.id), &(&1.pane_id == pane_id))

    # (c) proxy GETs for png + html return 200 with BrowserViewable content-types
    png_conn = auth_get(build_conn(), "/preview-proxy/#{workspace.id}/#{port}/shot.png")
    assert response(png_conn, 200) == png_bytes
    assert content_type(png_conn) =~ BrowserViewable.content_type("shot.png")
    assert BrowserViewable.content_type("shot.png") == "image/png"

    html_conn = auth_get(build_conn(), "/preview-proxy/#{workspace.id}/#{port}/report.html")
    assert html_conn.status == 200
    assert response(html_conn, 200) =~ "file-server-report"
    assert content_type(html_conn) =~ BrowserViewable.content_type("report.html")
    assert BrowserViewable.content_type("report.html") == "text/html"

    # Traversal through the proxy is still refused by FileServer/FileAccess (404).
    trav =
      auth_get(
        build_conn(),
        "/preview-proxy/#{workspace.id}/#{port}/" <> URI.encode("../etc/passwd")
      )

    assert trav.status == 404

    File.rm_rf!(root)
  end
end
