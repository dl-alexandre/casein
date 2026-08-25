defmodule Casein.MCP.ScopeTest.Source do
  @behaviour Casein.WorkspaceSource

  alias Casein.Workspace

  @workspace %Workspace{
    id: "ws-scope",
    name: "scope",
    user: "alice",
    branch: "main",
    status: :running,
    path: "/tmp/ws-scope",
    metadata: %{type: :v3, domain_base: "alice.devbox.example.com"}
  }

  def list(_opts, _auth), do: {:ok, [workspace()]}
  def get("ws-scope", _auth), do: {:ok, workspace()}
  def get(_id, _auth), do: {:error, :not_found}
  def create(_params, _auth), do: {:error, :not_implemented}
  def start(_id, _auth), do: {:error, :not_implemented}
  def stop(_id, _auth), do: {:error, :not_implemented}
  def delete(_id, _opts, _auth), do: {:error, :not_implemented}
  def stream_logs(_id, _service, _pid), do: {:error, :not_implemented}
  def safe_host_path(%{path: path}) when is_binary(path) and path != "", do: {:ok, path}
  def safe_host_path(_workspace), do: {:error, :missing_path}

  def safe_host_loc(workspace),
    do: with({:ok, path} <- safe_host_path(workspace), do: {:ok, {:local, path}})

  defp workspace do
    Application.get_env(:casein, :mcp_scope_test_workspace, @workspace)
  end
end

defmodule Casein.MCP.ScopeTest do
  use Casein.DataCase, async: false

  alias Casein.Agents.PreviewTools
  alias Casein.MCP.Scope
  alias Casein.PreviewControl.Registry
  alias Casein.Workspace
  alias Casein.Workspaces.Aliases, as: WorkspaceAliases
  alias Casein.Workspaces.State.MemoryAdapter

  setup do
    prev_source = Application.get_env(:casein, :workspace_source)
    prev_workspace = Application.get_env(:casein, :mcp_scope_test_workspace)
    prev_root = Application.get_env(:casein, :workspaces_root)

    MemoryAdapter.clear()
    _ = Registry.clear()
    Application.put_env(:casein, :workspace_source, Casein.MCP.ScopeTest.Source)

    on_exit(fn ->
      MemoryAdapter.clear()
      _ = Registry.clear()
      restore_env(:workspace_source, prev_source)
      restore_env(:mcp_scope_test_workspace, prev_workspace)
      restore_env(:workspaces_root, prev_root)
    end)

    :ok
  end

  test "every preview tool whose schema mentions workspace_id is in the scope allowlist" do
    allowlist = MapSet.new(Scope.preview_workspace_tool_names())

    missing =
      PreviewTools.definitions()
      |> Enum.filter(&mentions_workspace_id?/1)
      |> Enum.reject(fn %{name: name} -> MapSet.member?(allowlist, name) end)
      |> Enum.map(& &1.name)

    assert missing == [],
           "preview tools with workspace_id in schema missing from @preview_workspace_tools: #{inspect(missing)}"
  end

  test "injects a pre-scoped workspace for preview workspace tools" do
    assert {:ok, scope} =
             Scope.resolve_tool_call("preview_surfaces", %{},
               surface: :preview,
               default_workspace_id: "ws-scope"
             )

    assert scope.args["workspace_id"] == "ws-scope"
    assert scope.workspace_id == "ws-scope"
    assert scope.workspace.id == "ws-scope"
    assert scope.surface == :preview
    assert scope.resolved_from.workspace == :pre_scoped
  end

  test "rejects workspace overrides on pre-scoped endpoints" do
    assert {:error, error} =
             Scope.resolve_tool_call(
               "preview_surfaces",
               %{"workspace_id" => "ws-other"},
               surface: :preview,
               default_workspace_id: "ws-scope"
             )

    assert error.error == :workspace_scope_mismatch
    assert error.scoped_workspace_id == "ws-scope"
    assert error.requested_workspace_id == "ws-other"
    assert error.lane == "allow_cross_workspace"
  end

  test "allow_cross_workspace opens the read-only lane on a pre-scoped endpoint" do
    assert {:ok, scope} =
             Scope.resolve_tool_call(
               "terminal_list_sessions",
               %{"workspace_id" => "ws-other", "allow_cross_workspace" => true},
               surface: :terminal,
               default_workspace_id: "ws-scope"
             )

    assert scope.workspace_id == "ws-other"
    assert scope.args["cross_workspace"] == true
    assert scope.resolved_from.workspace == :cross_workspace_lane
  end

  test "allow_cross_workspace does not open mutating tools" do
    assert {:error, %{error: :workspace_scope_mismatch}} =
             Scope.resolve_tool_call(
               "terminal_send_command",
               %{"workspace_id" => "ws-other", "allow_cross_workspace" => true},
               surface: :terminal,
               default_workspace_id: "ws-scope"
             )
  end

  test "worker_launch inherits the coordinator workspace but rejects foreign overrides" do
    assert {:ok, scope} =
             Scope.resolve_tool_call(
               "worker_launch",
               %{
                 "session" => "casein_ws-scope_agent",
                 "runtime" => "opencode",
                 "task_slug" => "worker"
               },
               surface: :terminal,
               default_workspace_id: "ws-scope"
             )

    assert scope.args["workspace_id"] == "ws-scope"
    assert scope.resolved_from.workspace == :pre_scoped

    assert {:error, error} =
             Scope.resolve_tool_call(
               "worker_launch",
               %{
                 "workspace_id" => "ws-other",
                 "session" => "casein_ws-other_agent",
                 "runtime" => "opencode",
                 "task_slug" => "worker"
               },
               surface: :terminal,
               default_workspace_id: "ws-scope"
             )

    assert error.error == :workspace_scope_mismatch
    assert error.scoped_workspace_id == "ws-scope"
    assert error.requested_workspace_id == "ws-other"
  end

  test "accepts linked folder workspace ids inside a pre-scoped endpoint" do
    root = tmp_root!("scope-linked")
    workspace = Path.join(root, "demo")
    File.mkdir_p!(workspace)
    Application.put_env(:casein, :workspaces_root, root)

    Application.put_env(:casein, :mcp_scope_test_workspace, %Workspace{
      id: "ws-scope",
      name: "scope",
      user: "alice",
      branch: "main",
      status: :running,
      path: workspace,
      metadata: %{type: :v3}
    })

    folder_id = WorkspaceAliases.folder_id_for_path(workspace)

    assert {:ok, scope} =
             Scope.resolve_tool_call(
               "preview_surfaces",
               %{"workspace_id" => folder_id},
               surface: :preview,
               default_workspace_id: "ws-scope"
             )

    assert scope.workspace_id == folder_id
    assert scope.workspace.path == workspace
    assert scope.resolved_from.workspace == :args
  end

  test "resolves preview workspace tools from workspace_path aliases" do
    root = tmp_root!("scope-path")
    workspace = Path.join(root, "demo")
    File.mkdir_p!(workspace)
    Application.put_env(:casein, :workspaces_root, root)

    for key <- ["workspace_path", "path", "cwd"] do
      assert {:ok, scope} =
               Scope.resolve_tool_call("preview_surfaces", %{key => workspace}, surface: :preview)

      assert scope.workspace_id == WorkspaceAliases.folder_id_for_path(workspace)
      assert scope.workspace.path == workspace
      assert scope.resolved_from.workspace == :path
    end
  end

  test "resolves session-scoped preview workspace from registry" do
    :ok = Registry.put(123, %{preview: %{workspace_id: "ws-scope"}})

    assert {:ok, scope} =
             Scope.resolve_tool_call("preview_observe", %{"session_id" => "123"},
               surface: :preview
             )

    assert scope.workspace == %{}
    assert scope.workspace_id == "ws-scope"
    assert scope.resolved_from.workspace == :registry
  end

  test "injects and enforces pre-scoped tmux sessions for preview open tools" do
    assert {:ok, scope} =
             Scope.resolve_tool_call("preview_open_app", %{"workspace_id" => "ws-scope"},
               surface: :preview,
               default_tmux_session: "casein_ws-scope_agent"
             )

    assert scope.args["tmux_session"] == "casein_ws-scope_agent"
    assert scope.tmux_session == "casein_ws-scope_agent"
    assert scope.resolved_from.tmux_session == :pre_scoped

    assert {:error, error} =
             Scope.resolve_tool_call(
               "preview_open_app",
               %{"workspace_id" => "ws-scope", "tmux_session" => "casein_ws-scope_other"},
               surface: :preview,
               default_tmux_session: "casein_ws-scope_agent"
             )

    assert error.error == :tmux_session_scope_mismatch
    assert error.scoped_tmux_session == "casein_ws-scope_agent"
    assert error.requested_tmux_session == "casein_ws-scope_other"
  end

  test "accepts a workspace-name alias of the pre-scoped tmux session" do
    {:ok, _} =
      Casein.Workspaces.State.sync(%Workspace{
        id: "ws-scope",
        name: "scope",
        path: "/tmp/ws-scope",
        status: :running
      })

    scoped = Casein.Terminals.Tmux.session_name("ws-scope", "agent")
    alias_session = Casein.Terminals.Tmux.session_name("scope", "agent")

    assert {:ok, scope} =
             Scope.resolve_tool_call(
               "preview_ensure_server_here",
               %{"workspace_id" => "ws-scope", "tmux_session" => alias_session},
               surface: :preview,
               default_tmux_session: scoped,
               default_workspace_id: "ws-scope"
             )

    assert scope.args["tmux_session"] == alias_session
    assert scope.resolved_from.tmux_session == :args
  end

  test "resolves playback opens as workspace-scoped preview tools" do
    assert {:ok, scope} =
             Scope.resolve_tool_call(
               "preview_playback_open",
               %{"artifact_path" => "/preview-artifacts/ws-scope/demo.webm"},
               surface: :preview,
               default_workspace_id: "ws-scope",
               default_tmux_session: "casein_ws-scope_agent"
             )

    assert scope.workspace_id == "ws-scope"
    assert scope.workspace.id == "ws-scope"
    assert scope.args["workspace_id"] == "ws-scope"
    assert scope.args["tmux_session"] == "casein_ws-scope_agent"
    assert scope.resolved_from.workspace == :pre_scoped
    assert scope.resolved_from.tmux_session == :pre_scoped
  end

  test "resolves compare_snapshots as a workspace-scoped preview tool" do
    assert {:ok, scope} =
             Scope.resolve_tool_call(
               "preview_compare_snapshots",
               %{
                 "artifact_a" => "/preview-artifacts/ws-scope/1.png",
                 "artifact_b" => "/preview-artifacts/ws-scope/2.png"
               },
               surface: :preview,
               default_workspace_id: "ws-scope"
             )

    assert scope.workspace_id == "ws-scope"
    assert scope.workspace.id == "ws-scope"
    assert scope.args["workspace_id"] == "ws-scope"
  end

  test "terminal surface injects exact workspace and tmux session scope" do
    assert {:ok, scope} =
             Scope.resolve_tool_call("terminal_list_sessions", %{},
               surface: :terminal,
               default_workspace_id: "ws-scope",
               default_tmux_session: "casein_ws-scope_wt-coordinator"
             )

    assert scope.args["workspace_id"] == "ws-scope"
    assert scope.args["session"] == "casein_ws-scope_wt-coordinator"
    assert scope.workspace == %{}
    assert scope.workspace_id == "ws-scope"
    assert scope.tmux_session == "casein_ws-scope_wt-coordinator"
    assert scope.resolved_from.workspace == :pre_scoped
    assert scope.resolved_from.tmux_session == :pre_scoped
  end

  test "terminal session scope rejects a different or foreign session" do
    opts = [
      surface: :terminal,
      default_workspace_id: "ws-scope",
      default_tmux_session: "casein_ws-scope_wt-coordinator"
    ]

    assert {:error, error} =
             Scope.resolve_tool_call(
               "terminal_context",
               %{"session" => "casein_ws-scope_wt-other"},
               opts
             )

    assert error.error == :tmux_session_scope_mismatch
    assert error.scoped_tmux_session == "casein_ws-scope_wt-coordinator"
    assert error.requested_tmux_session == "casein_ws-scope_wt-other"

    assert {:error, foreign} =
             Scope.resolve_tool_call("terminal_context", %{},
               surface: :terminal,
               default_workspace_id: "ws-scope",
               default_tmux_session: "casein_ws-other_wt-coordinator"
             )

    assert foreign.error == :tmux_session_workspace_mismatch
  end

  test "every exact-session terminal tool accepts session in its schema" do
    by_name = Map.new(Casein.Agents.TerminalTools.definitions(), &{&1.name, &1})

    for tool_name <- Scope.terminal_default_tmux_session_tool_names() do
      tool = Map.fetch!(by_name, tool_name)
      assert Map.has_key?(tool.parameters.properties, :session), tool_name
    end
  end

  test "every caller-pane tool accepts caller_pane in its schema" do
    by_name = Map.new(Casein.Agents.TerminalTools.definitions(), &{&1.name, &1})

    for tool_name <- Scope.terminal_caller_pane_tool_names() do
      tool = Map.fetch!(by_name, tool_name)
      assert Map.has_key?(tool.parameters.properties, :caller_pane), tool_name
    end
  end

  test "injects the transport caller pane for caller-pane terminal tools" do
    assert {:ok, scope} =
             Scope.resolve_tool_call("terminal_context", %{},
               surface: :terminal,
               default_workspace_id: "ws-scope",
               default_caller_pane: "%7"
             )

    assert scope.args["caller_pane"] == "%7"
    assert scope.resolved_from.caller_pane == :pre_scoped
  end

  test "explicit caller_pane args win over the transport default" do
    assert {:ok, scope} =
             Scope.resolve_tool_call("terminal_context", %{"caller_pane" => "%3"},
               surface: :terminal,
               default_workspace_id: "ws-scope",
               default_caller_pane: "%7"
             )

    assert scope.args["caller_pane"] == "%3"
    assert scope.resolved_from.caller_pane == :args
  end

  test "does not inject caller_pane into tools outside the caller-pane allowlist" do
    assert {:ok, scope} =
             Scope.resolve_tool_call("terminal_list_sessions", %{},
               surface: :terminal,
               default_workspace_id: "ws-scope",
               default_caller_pane: "%7"
             )

    refute Map.has_key?(scope.args, "caller_pane")
    assert scope.resolved_from.caller_pane == nil
  end

  test "unscoped terminal listing is refused without a workspace" do
    assert {:error, error} =
             Scope.resolve_tool_call("terminal_list_sessions", %{}, surface: :terminal)

    assert error.error == :workspace_scope_required
    assert error.lane == "allow_cross_workspace"
  end

  test "unscoped terminal listing is allowed when global tool calls are enabled" do
    prev = Application.get_env(:casein, :allow_global_mcp_tool_calls)
    Application.put_env(:casein, :allow_global_mcp_tool_calls, true)

    on_exit(fn -> restore_env(:allow_global_mcp_tool_calls, prev) end)

    assert {:ok, scope} =
             Scope.resolve_tool_call("terminal_list_sessions", %{}, surface: :terminal)

    assert scope.workspace_id == nil
  end

  defp mentions_workspace_id?(%{parameters: params}) when is_map(params) do
    properties = Map.get(params, :properties) || Map.get(params, "properties") || %{}
    required = Map.get(params, :required) || Map.get(params, "required") || []

    Map.has_key?(properties, :workspace_id) or Map.has_key?(properties, "workspace_id") or
      "workspace_id" in required
  end

  defp tmp_root!(name) do
    root = Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp restore_env(key, nil), do: Application.delete_env(:casein, key)
  defp restore_env(key, value), do: Application.put_env(:casein, key, value)
end
