defmodule CaseinWeb.API.ArtifactMCPControllerTest do
  @moduledoc """
  HTTP transport + auth tests for POST /api/artifacts/mcp.
  """
  use CaseinWeb.ConnCase, async: false

  alias Casein.Agents.Activity
  alias Casein.Runtimes
  alias Casein.Workspace
  alias Casein.Workspaces.State
  alias Casein.Workspaces.State.MemoryAdapter

  @global_token "test-artifact-mcp-global-token"
  @workspace_token "test-artifact-mcp-workspace-token"
  @workspace_id "ws-artifacts-mcp"

  setup do
    prev_token = Application.get_env(:casein, :api_token)
    prev_workspace_tokens = Application.get_env(:casein, :workspace_api_tokens)
    prev_artifact_root = Application.get_env(:casein, :artifact_projects_root)
    prev_agent_roots = Application.get_env(:casein, :agent_worktree_roots)
    prev_launcher_enabled = Application.get_env(:casein, :runtime_preview_launcher_enabled)
    prev_runtimes_adapter = Application.get_env(:casein, :runtimes_adapter)
    prev_workspace_state_adapter = Application.get_env(:casein, :workspace_state_adapter)

    base = Path.join(System.tmp_dir!(), "artifact-mcp-#{System.unique_integer([:positive])}")
    repo = Path.join(base, "repo")
    artifact_root = Path.join(base, "artifacts")

    Application.put_env(:casein, :api_token, @global_token)
    Application.put_env(:casein, :workspace_api_tokens, %{@workspace_token => @workspace_id})
    Application.put_env(:casein, :workspace_state_adapter, MemoryAdapter)
    Application.put_env(:casein, :runtimes_adapter, Casein.Runtimes.MemoryAdapter)
    Application.put_env(:casein, :artifact_projects_root, artifact_root)
    Application.put_env(:casein, :agent_worktree_roots, [])
    Application.put_env(:casein, :runtime_preview_launcher_enabled, false)

    MemoryAdapter.clear()
    Runtimes.clear()
    Activity.clear()
    init_repo!(repo)
    seed_workspace!(@workspace_id, "artifact-ws", repo)

    on_exit(fn ->
      MemoryAdapter.clear()
      Runtimes.clear()
      Activity.clear()
      File.rm_rf!(base)

      restore_env(:api_token, prev_token)
      restore_env(:workspace_api_tokens, prev_workspace_tokens)
      restore_env(:artifact_projects_root, prev_artifact_root)
      restore_env(:agent_worktree_roots, prev_agent_roots)
      restore_env(:runtime_preview_launcher_enabled, prev_launcher_enabled)
      restore_env(:runtimes_adapter, prev_runtimes_adapter)
      restore_env(:workspace_state_adapter, prev_workspace_state_adapter)
    end)

    %{base: base, repo: repo}
  end

  test "requires a bearer token", %{conn: conn} do
    conn = post_mcp(conn, %{jsonrpc: "2.0", id: 1, method: "tools/list"}, nil)
    assert conn.status == 401
  end

  test "tools/list returns artifact tools with a valid token", %{conn: conn} do
    conn = post_mcp(conn, %{jsonrpc: "2.0", id: 1, method: "tools/list"}, @global_token)

    assert %{"result" => %{"tools" => tools}} = json_response(conn, 200)
    assert Enum.any?(tools, &(&1["name"] == "artifact_create"))
    assert Enum.any?(tools, &(&1["name"] == "artifact_update"))
    assert Enum.any?(tools, &(&1["name"] == "artifact_verify"))
    assert Enum.any?(tools, &(&1["name"] == "artifact_snapshot"))
    assert Enum.any?(tools, &(&1["name"] == "artifact_retire"))
  end

  test "workspace-scoped token scopes artifact tool schema", %{conn: conn} do
    conn = post_mcp(conn, %{jsonrpc: "2.0", id: 1, method: "tools/list"}, @workspace_token)

    assert %{"result" => %{"tools" => tools}} = json_response(conn, 200)
    create = Enum.find(tools, &(&1["name"] == "artifact_create"))
    refute "workspace_id" in create["inputSchema"]["required"]
  end

  test "global token cannot call Artifact MCP tools", %{conn: conn} do
    conn =
      post_mcp(
        conn,
        %{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{
            name: "artifact_list",
            arguments: %{workspace_id: @workspace_id}
          }
        },
        @global_token
      )

    assert %{
             "error" => "workspace_scoped_token_required",
             "code" => "workspace_scoped_token_required",
             "error_version" => "mcp-auth-v1",
             "tool" => "artifact_list"
           } = json_response(conn, 403)
  end

  test "workspace-scoped token creates an artifact project", %{conn: conn} do
    conn =
      post_mcp(
        conn,
        %{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{
            name: "artifact_create",
            arguments: %{
              name: "MCP Artifact",
              prompt: "Build a local artifact preview",
              files: %{"index.html" => "<h1>MCP Artifact</h1>\n"}
            }
          }
        },
        @workspace_token
      )

    assert %{
             "result" => %{
               "structuredContent" => %{
                 "id" => artifact_id,
                 "workspace_id" => @workspace_id,
                 "name" => "MCP Artifact",
                 "worktree_path" => worktree_path,
                 "preview_open_arguments" => %{
                   "workspace_id" => @workspace_id,
                   "mode" => "app",
                   "runtime_id" => artifact_id
                 },
                 "next_tool" => "preview_open",
                 "next_arguments" => %{"runtime_id" => artifact_id}
               }
             }
           } = json_response(conn, 200)

    assert String.starts_with?(artifact_id, "art-")
    assert File.read!(Path.join(worktree_path, "index.html")) =~ "MCP Artifact"

    assert [%{source: :artifact_mcp, tool: "artifact_create", status: :ok}] =
             Activity.recent(@workspace_id)
  end

  test "artifact_create decodes base64 files and imports workspace-local source files", %{
    conn: conn,
    repo: repo
  } do
    png = <<137, 80, 78, 71, 13, 10, 26, 10, 0, 255>>
    File.write!(Path.join(repo, "source.bin"), <<0, 1, 2, 3>>)

    conn =
      post_mcp(
        conn,
        %{
          jsonrpc: "2.0",
          id: 2,
          method: "tools/call",
          params: %{
            name: "artifact_create",
            arguments: %{
              name: "Binary Artifact",
              files: [
                %{path: "shot.png", content: Base.encode64(png), encoding: "base64"},
                %{path: "assets/source.bin", source_path: "source.bin"}
              ]
            }
          }
        },
        @workspace_token
      )

    assert %{
             "result" => %{
               "structuredContent" => %{"worktree_path" => worktree_path}
             }
           } = json_response(conn, 200)

    assert File.read!(Path.join(worktree_path, "shot.png")) == png
    assert File.read!(Path.join(worktree_path, "assets/source.bin")) == <<0, 1, 2, 3>>
  end

  test "artifact_create rejects invalid base64 and source paths outside the workspace", %{
    conn: conn,
    base: base
  } do
    outside = Path.join(base, "outside.bin")
    File.write!(outside, "secret")

    for file <- [
          %{path: "shot.png", content: "not-base64!", encoding: "base64"},
          %{path: "outside.bin", source_path: outside}
        ] do
      conn =
        post_mcp(
          recycle(conn),
          %{
            jsonrpc: "2.0",
            id: 3,
            method: "tools/call",
            params: %{
              name: "artifact_create",
              arguments: %{name: "Rejected Import", files: [file]}
            }
          },
          @workspace_token
        )

      assert %{"result" => %{"isError" => true}} = json_response(conn, 200)
    end
  end

  test "artifact_get rejects an artifact from another workspace", %{conn: conn, base: base} do
    other_repo = Path.join(base, "other-repo")
    init_repo!(other_repo)
    seed_workspace!("ws-other-artifacts", "other-artifacts", other_repo)

    assert {:ok, other_project} =
             Casein.ArtifactProjects.create("ws-other-artifacts", %{
               name: "Other Artifact",
               files: %{"index.html" => "<h1>Other</h1>\n"}
             })

    conn =
      post_mcp(
        conn,
        %{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{name: "artifact_get", arguments: %{artifact_id: other_project.id}}
        },
        @workspace_token
      )

    assert %{
             "result" => %{
               "isError" => true,
               "structuredContent" => %{
                 "error" => "workspace_scope_mismatch",
                 "scoped_workspace_id" => @workspace_id,
                 "requested_workspace_id" => "ws-other-artifacts"
               }
             }
           } = json_response(conn, 200)
  end

  test "workspace-scoped token retires its artifact project", %{conn: conn} do
    assert {:ok, project} =
             Casein.ArtifactProjects.create(@workspace_id, %{
               name: "Retire Through MCP",
               files: %{"index.html" => "<h1>Retire</h1>\n"}
             })

    conn =
      post_mcp(
        conn,
        %{
          jsonrpc: "2.0",
          id: 8,
          method: "tools/call",
          params: %{name: "artifact_retire", arguments: %{artifact_id: project.id}}
        },
        @workspace_token
      )

    assert %{
             "result" => %{
               "structuredContent" => %{
                 "id" => artifact_id,
                 "status" => "cleaned",
                 "retired" => true,
                 "restorable" => true
               }
             }
           } = json_response(conn, 200)

    assert artifact_id == project.id
    refute File.exists?(project.worktree_path)
  end

  test "notifications get a 202 with no JSON-RPC body", %{conn: conn} do
    conn =
      post_mcp(conn, %{jsonrpc: "2.0", method: "notifications/initialized"}, @global_token)

    assert conn.status == 202
    assert conn.resp_body == ""
  end

  defp post_mcp(conn, body, token, path \\ "/api/artifacts/mcp") do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
    |> then(fn c ->
      if token, do: put_req_header(c, "authorization", "Bearer " <> token), else: c
    end)
    |> post(path, body)
  end

  defp seed_workspace!(id, name, repo) do
    {:ok, _record} =
      State.sync(%Workspace{
        id: id,
        name: name,
        path: repo,
        status: :running,
        metadata: %{"id" => id, "name" => name}
      })
  end

  defp init_repo!(repo) do
    File.mkdir_p!(repo)
    git!(repo, ["init"])
    git!(repo, ["config", "user.name", "Casein Test"])
    git!(repo, ["config", "user.email", "casein-test@localhost"])
    File.write!(Path.join(repo, "README.md"), "# Artifact MCP Test\n")
    git!(repo, ["add", "README.md"])
    git!(repo, ["commit", "-m", "Initial commit"])
  end

  defp git!(cwd, args) do
    case System.cmd("git", ["-C", cwd | args], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, code} -> flunk("git #{Enum.join(args, " ")} failed with #{code}: #{output}")
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:casein, key)
  defp restore_env(key, value), do: Application.put_env(:casein, key, value)
end
