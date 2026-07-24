defmodule CaseinWeb.WorkspaceFileControllerTest do
  use CaseinWeb.ConnCase, async: false

  defmodule OwnedSource do
    alias Casein.Workspace

    def get(id, _auth) do
      root = Application.fetch_env!(:dev_ide, :workspace_file_controller_root)

      {:ok,
       %Workspace{
         id: id,
         name: id,
         user: "owner",
         path: root,
         status: :running,
         metadata: %{attached_folder: true}
       }}
    end
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "workspace-file-test-#{System.unique_integer([:positive])}")

    File.rm_rf!(root)
    File.mkdir_p!(root)

    prev_source = Application.get_env(:dev_ide, :workspace_source)
    prev_root = Application.get_env(:dev_ide, :workspace_file_controller_root)
    prev_fa = Application.get_env(:dev_ide, :forward_auth)

    Application.put_env(:dev_ide, :workspace_source, OwnedSource)
    Application.put_env(:dev_ide, :workspace_file_controller_root, root)
    Application.put_env(:dev_ide, :forward_auth, true)

    on_exit(fn ->
      File.rm_rf(root)
      restore(:workspace_source, prev_source)
      restore(:workspace_file_controller_root, prev_root)
      restore(:forward_auth, prev_fa)
    end)

    {:ok, root: root}
  end

  test "serves a regular workspace file to the owner with no-store", %{conn: conn, root: root} do
    File.mkdir_p!(Path.join(root, "docs"))
    File.write!(Path.join(root, "docs/readme.txt"), "hello")

    conn =
      conn
      |> as("owner@example.com")
      |> get("/api/workspaces/ws-files/files/docs/readme.txt")

    assert response(conn, 200) == "hello"
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
  end

  test "does not serve same-origin html as executable html", %{conn: conn, root: root} do
    File.write!(Path.join(root, "page.html"), "<script>alert(1)</script>")

    conn =
      conn
      |> as("owner@example.com")
      |> get("/api/workspaces/ws-files/files/page.html")

    assert response(conn, 200) == "<script>alert(1)</script>"
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
  end

  test "serves files to any authenticated peer (flat peer model)", %{conn: conn, root: root} do
    File.write!(Path.join(root, "shared.txt"), "shared")

    conn =
      conn
      |> as("peer@example.com")
      |> get("/api/workspaces/ws-files/files/shared.txt")

    assert response(conn, 200) == "shared"
  end

  test "returns 404 for traversal attempts", %{conn: conn, root: root} do
    outside = Path.join(Path.dirname(root), "outside-secret.txt")
    File.write!(outside, "secret")

    on_exit(fn -> File.rm(outside) end)

    conn =
      conn
      |> as("owner@example.com")
      |> get("/api/workspaces/ws-files/files/%2e%2e/outside-secret.txt")

    assert text_response(conn, 404) =~ "not found"
  end

  test "returns 404 for directories", %{conn: conn, root: root} do
    File.mkdir_p!(Path.join(root, "docs"))

    conn =
      conn
      |> as("owner@example.com")
      |> get("/api/workspaces/ws-files/files/docs")

    assert text_response(conn, 404) =~ "not found"
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, val), do: Application.put_env(:dev_ide, key, val)

  defp as(conn, email), do: put_req_header(conn, "x-auth-request-email", email)
end
