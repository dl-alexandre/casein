defmodule DevIdeWeb.API.WorkspaceOpenControllerTest do
  use DevIdeWeb.ConnCase, async: false

  alias DevIDE.Links.Open
  @token "workspace-open-token"

  defmodule Source do
    alias DevIDE.Workspace

    def get(id, _auth) do
      root = Application.fetch_env!(:dev_ide, :workspace_open_controller_root)

      {:ok,
       %Workspace{
         id: id,
         name: id,
         user: "owner",
         path: root,
         status: :running,
         metadata: %{attached_folder: true, detected_ports: [4040]}
       }}
    end
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "workspace-open-test-#{System.unique_integer([:positive])}")

    File.rm_rf!(root)
    File.mkdir_p!(Path.join(root, "docs"))
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "docs/readme.md"), "# Readme\n")
    File.write!(Path.join(root, "lib/foo.ex"), "defmodule Foo, do: :ok\n")

    prev_token = Application.get_env(:dev_ide, :api_token)
    prev_workspace_tokens = Application.get_env(:dev_ide, :workspace_api_tokens)
    prev_source = Application.get_env(:dev_ide, :workspace_source)
    prev_root = Application.get_env(:dev_ide, :workspace_open_controller_root)

    Application.put_env(:dev_ide, :api_token, @token)
    Application.put_env(:dev_ide, :workspace_source, Source)
    Application.put_env(:dev_ide, :workspace_open_controller_root, root)

    on_exit(fn ->
      File.rm_rf(root)
      restore(:api_token, prev_token)
      restore(:workspace_api_tokens, prev_workspace_tokens)
      restore(:workspace_source, prev_source)
      restore(:workspace_open_controller_root, prev_root)
    end)

    {:ok, root: root}
  end

  test "workspace-scoped tokens cannot open another workspace", %{conn: conn} do
    Application.put_env(:dev_ide, :workspace_api_tokens, %{"scoped-token" => "other-workspace"})

    body =
      conn
      |> open_target("ws-open", %{target: "docs/readme.md"}, "scoped-token")
      |> json_response(403)

    assert body == %{"error" => "workspace_forbidden"}
  end

  test "resolves and broadcasts a file target", %{conn: conn, root: root} do
    :ok = Open.subscribe("ws-open")

    body =
      conn
      |> open_target("ws-open", %{
        target: "foo.ex:12:3",
        base_dir: Path.join(root, "lib")
      })
      |> json_response(200)

    assert body == %{"kind" => "file", "path" => "lib/foo.ex", "line" => 12, "col" => 3}

    assert_receive {:open_target, {:file, %{path: "lib/foo.ex", line: 12, col: 3}}}
  end

  test "returns markdown targets as typed JSON", %{conn: conn} do
    body =
      conn
      |> open_target("ws-open", %{target: "docs/readme.md#intro"})
      |> json_response(200)

    assert body == %{"kind" => "markdown", "path" => "docs/readme.md", "anchor" => "intro"}
  end

  test "returns 404 for candidates that do not verify", %{conn: conn} do
    body =
      conn
      |> open_target("ws-open", %{target: "docs/missing.md"})
      |> json_response(404)

    assert body == %{"error" => "not_found"}
  end

  test "returns 422 for rejected targets", %{conn: conn} do
    body =
      conn
      |> open_target("ws-open", %{target: "javascript:alert(1)"})
      |> json_response(422)

    assert body == %{"error" => "scheme_not_allowed"}
  end

  defp open_target(conn, workspace_id, params, token \\ @token) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("accept", "application/json")
    |> post("/api/workspaces/#{workspace_id}/open", params)
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, val), do: Application.put_env(:dev_ide, key, val)
end
