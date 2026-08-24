defmodule CaseinWeb.API.CodeMCPControllerTest do
  @moduledoc """
  HTTP transport + auth + scope tests for POST /api/code/mcp.
  """
  use CaseinWeb.ConnCase, async: false

  alias Casein.Agents.Activity
  alias Casein.Runtimes
  alias Casein.Workspace
  alias Casein.Workspaces.State
  alias Casein.Workspaces.State.MemoryAdapter

  @global_token "test-code-mcp-global-token"
  @workspace_token "test-code-mcp-workspace-token"
  @workspace_id "ws-code-mcp"

  setup do
    prev_token = Application.get_env(:casein, :api_token)
    prev_workspace_tokens = Application.get_env(:casein, :workspace_api_tokens)
    prev_runtimes_adapter = Application.get_env(:casein, :runtimes_adapter)
    prev_workspace_state_adapter = Application.get_env(:casein, :workspace_state_adapter)

    base = Path.join(System.tmp_dir!(), "code-mcp-#{System.unique_integer([:positive])}")
    repo = Path.join(base, "repo")

    Application.put_env(:casein, :api_token, @global_token)
    Application.put_env(:casein, :workspace_api_tokens, %{@workspace_token => @workspace_id})
    Application.put_env(:casein, :workspace_state_adapter, MemoryAdapter)
    Application.put_env(:casein, :runtimes_adapter, Casein.Runtimes.MemoryAdapter)

    MemoryAdapter.clear()
    Runtimes.clear()
    Activity.clear()
    init_repo!(repo)
    seed_workspace!(@workspace_id, "code-mcp", repo)

    on_exit(fn ->
      MemoryAdapter.clear()
      Runtimes.clear()
      Activity.clear()
      File.rm_rf!(base)
      restore_env(:api_token, prev_token)
      restore_env(:workspace_api_tokens, prev_workspace_tokens)
      restore_env(:runtimes_adapter, prev_runtimes_adapter)
      restore_env(:workspace_state_adapter, prev_workspace_state_adapter)
    end)

    %{repo: repo}
  end

  test "requires a bearer token", %{conn: conn} do
    conn = post_mcp(conn, %{jsonrpc: "2.0", id: 1, method: "tools/list"}, nil)
    assert conn.status == 401
  end

  test "tools/list returns code tools", %{conn: conn} do
    conn = post_mcp(conn, %{jsonrpc: "2.0", id: 1, method: "tools/list"}, @global_token)
    assert %{"result" => %{"tools" => tools}} = json_response(conn, 200)
    names = Enum.map(tools, & &1["name"])
    assert "code_read" in names
    assert "code_search" in names
    assert "code_apply_patch" in names
    assert "code_exec" in names
  end

  test "workspace-scoped token injects workspace_id and reads a file", %{conn: conn, repo: repo} do
    conn =
      post_mcp(
        conn,
        %{
          jsonrpc: "2.0",
          id: 2,
          method: "tools/call",
          params: %{
            name: "code_read",
            arguments: %{worktree_path: repo, path: "README.md"}
          }
        },
        @workspace_token
      )

    assert %{
             "result" => %{
               "structuredContent" => %{
                 "path" => "README.md",
                 "content" => content,
                 "workspace_id" => @workspace_id
               }
             }
           } = json_response(conn, 200)

    assert content =~ "Code MCP"
  end

  test "cross-workspace override is rejected", %{conn: conn, repo: repo} do
    conn =
      post_mcp(
        conn,
        %{
          jsonrpc: "2.0",
          id: 3,
          method: "tools/call",
          params: %{
            name: "code_read",
            arguments: %{
              workspace_id: "ws-other-code",
              worktree_path: repo,
              path: "README.md"
            }
          }
        },
        @workspace_token
      )

    assert %{
             "result" => %{
               "structuredContent" => %{
                 "error" => "workspace_scope_mismatch",
                 "scoped_workspace_id" => @workspace_id,
                 "requested_workspace_id" => "ws-other-code"
               }
             }
           } = json_response(conn, 200)
  end

  test "path escape is a structured tool error", %{conn: conn, repo: repo} do
    conn =
      post_mcp(
        conn,
        %{
          jsonrpc: "2.0",
          id: 4,
          method: "tools/call",
          params: %{
            name: "code_read",
            arguments: %{worktree_path: repo, path: "../escape"}
          }
        },
        @workspace_token
      )

    assert %{
             "result" => %{
               "structuredContent" => %{"error" => error}
             }
           } = json_response(conn, 200)

    assert error in ["outside_root", "absolute_path"]
  end

  test "read → patch → exec fixture flow uses only the structured surface", %{
    conn: conn,
    repo: repo
  } do
    File.write!(Path.join(repo, "note.txt"), "alpha\n")
    git!(repo, ["add", "note.txt"])
    git!(repo, ["commit", "-m", "note"])
    File.write!(Path.join(repo, "note.txt"), "beta\n")
    patch = git_diff!(repo, "note.txt")
    File.write!(Path.join(repo, "note.txt"), "alpha\n")

    read =
      post_mcp(
        conn,
        call("code_read", %{worktree_path: repo, path: "note.txt"}),
        @workspace_token
      )

    assert %{"result" => %{"structuredContent" => %{"content" => "alpha\n"}}} =
             json_response(read, 200)

    apply =
      post_mcp(
        recycle(read),
        call("code_apply_patch", %{worktree_path: repo, patch: patch, task_id: "t1"}),
        @workspace_token
      )

    assert %{"result" => %{"structuredContent" => %{"applied" => true, "paths" => ["note.txt"]}}} =
             json_response(apply, 200)

    exec =
      post_mcp(
        recycle(apply),
        call("code_exec", %{worktree_path: repo, command_id: "format", timeout_ms: 5_000}),
        @workspace_token
      )

    assert %{"result" => %{"structuredContent" => payload}} = json_response(exec, 200)
    assert payload["command_id"] == "format"
    assert payload["argv"] == ["mix", "format", "--check-formatted"]
    assert is_boolean(payload["timed_out"])
    assert is_boolean(payload["output_truncated"])
    assert File.read!(Path.join(repo, "note.txt")) == "beta\n"
  end

  test "notifications get a 202 with no JSON-RPC body", %{conn: conn} do
    conn = post_mcp(conn, %{jsonrpc: "2.0", method: "notifications/initialized"}, @global_token)
    assert conn.status == 202
    assert conn.resp_body == ""
  end

  defp call(name, args) do
    %{
      jsonrpc: "2.0",
      id: System.unique_integer([:positive]),
      method: "tools/call",
      params: %{name: name, arguments: args}
    }
  end

  defp post_mcp(conn, body, token) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
    |> then(fn c ->
      if token, do: put_req_header(c, "authorization", "Bearer " <> token), else: c
    end)
    |> post("/api/code/mcp", body)
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
    File.write!(Path.join(repo, "README.md"), "# Code MCP\n")
    git!(repo, ["add", "README.md"])
    git!(repo, ["commit", "-m", "Initial commit"])
  end

  defp git_diff!(cwd, path) do
    case System.cmd("git", ["-C", cwd, "diff", "--", path], stderr_to_stdout: true) do
      {output, code} when code in [0, 1] and output != "" -> output
      {output, code} -> flunk("git diff failed with #{code}: #{output}")
    end
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
