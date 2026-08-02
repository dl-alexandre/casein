defmodule Casein.Desktop.NativeAgentLaunchTest do
  use ExUnit.Case, async: true

  alias Casein.Desktop.NativeAgentLaunch

  test "preflights and prepares token-free launch plans for every native provider" do
    root = temp_root()
    staging = Path.join(root, "staging")
    File.mkdir_p!(Path.join(staging, "grok"))
    File.write!(Path.join([staging, "grok", ".mcp.json"]), ~s({"token":"${CASEIN_API_TOKEN}"}))
    File.write!(Path.join(staging, "opencode.json"), ~s({"token":"{env:CASEIN_API_TOKEN}"}))
    File.write!(Path.join(staging, ".mcp.json"), "{}")
    File.write!(Path.join(staging, "claude-hooks-settings.json"), "{}")

    for runtime <- ~w(codex claude grok opencode cursor) do
      checkout = Path.join(root, runtime)
      File.mkdir_p!(checkout)

      assert {:ok, plan} =
               NativeAgentLaunch.prepare(workspace(root), runtime, "ticket-462",
                 diagnoser: fn ^runtime, _opts ->
                   {:ok,
                    %{
                      executable_status: :available,
                      version: {:ok, "1.2.3"},
                      auth: :provider_managed
                    }}
                 end,
                 creator: fn ^root, ^runtime, "ticket-462", _opts ->
                   {:ok,
                    %{
                      path: checkout,
                      branch: "agent/#{runtime}/ticket-462",
                      base_ref: "origin/master",
                      primary: root
                    }}
                 end,
                 environment_builder: fn _workspace, ^checkout ->
                   {:ok, environment(staging, checkout)}
                 end,
                 reporter: fn "workspace-1", attrs ->
                   assert attrs["agent"] == runtime
                   assert attrs["worktree_path"] == checkout
                   {:ok, attrs}
                 end
               )

      assert plan.command =~ checkout
      refute plan.command =~ "secret-token"
      refute inspect(plan) =~ "secret-token"
    end

    assert File.read!(Path.join(root, "grok/.mcp.json")) =~ "${CASEIN_API_TOKEN}"

    assert File.read!(Path.join(root, "opencode/.opencode/opencode.json")) =~
             "{env:CASEIN_API_TOKEN}"

    File.rm_rf!(root)
  end

  test "fails preflight before creating a worktree" do
    assert {:error, :executable_missing} =
             NativeAgentLaunch.prepare(workspace("C:/repo"), "codex", "task",
               diagnoser: fn "codex", _ ->
                 {:ok,
                  %{executable_status: :missing, version: {:error, :missing}, auth: :signed_in}}
               end,
               creator: fn _, _, _, _ -> flunk("creator must not run") end
             )
  end

  test "starts the token-free command in the prepared worktree session" do
    plan = %{plan("C:/worktrees/launch") | workspace: workspace("C:/repo"), command: "codex\r"}
    parent = self()

    assert :ok =
             NativeAgentLaunch.start(plan,
               ensure_session: fn "C:/worktrees/launch", workspace ->
                 send(parent, {:ensured, workspace.id})
                 :ok
               end,
               send_input: fn workspace, "codex\r" ->
                 send(parent, {:sent, workspace.id})
                 :ok
               end
             )

    assert_receive {:ensured, "workspace-1"}
    assert_receive {:sent, "workspace-1"}
  end

  test "failed native session start records a token-free handoff" do
    plan = %{plan("C:/worktrees/launch") | workspace: workspace("C:/repo"), command: "codex\r"}
    parent = self()

    assert {:error, :conpty_unavailable} =
             NativeAgentLaunch.start(plan,
               ensure_session: fn _, _ -> {:error, :conpty_unavailable} end,
               send_input: fn _, _ -> flunk("command must not be sent") end,
               reporter: fn "workspace-1", attrs ->
                 send(parent, {:handoff, attrs})
                 {:ok, attrs}
               end
             )

    assert_receive {:handoff,
                    %{
                      "exit_status" => "handoff",
                      "handoff" => "native codex session launch failed"
                    }}
  end

  test "finish reports every exit and removes only clean landed worktrees" do
    plan = plan("C:/worktrees/clean")
    parent = self()

    reporter = fn "workspace-1", attrs ->
      send(parent, {:reported, attrs})
      {:ok, attrs}
    end

    git = fn
      ["-C", "C:/worktrees/clean", "status", "--porcelain"], [] -> {"", 0}
      ["-C", "C:/repo", "worktree", "remove", "--", "C:/worktrees/clean"], [] -> {"", 0}
    end

    assert {:ok, %{removed: true}} =
             NativeAgentLaunch.finish(plan, "landed", nil, reporter: reporter, git: git)

    assert_receive {:reported, %{"exit_status" => "landed"}}

    assert {:ok, %{removed: false, reason: :handoff_preserved}} =
             NativeAgentLaunch.finish(plan, "wip", "tests pending",
               reporter: reporter,
               git: fn _, _ -> flunk("git must not run for a handoff") end
             )

    assert_receive {:reported, %{"exit_status" => "wip", "handoff" => "tests pending"}}
  end

  test "dirty landed worktree is reported but preserved" do
    assert {:ok, %{removed: false, reason: :dirty_worktree}} =
             NativeAgentLaunch.finish(plan("C:/worktrees/dirty"), "landed", nil,
               reporter: fn _, attrs -> {:ok, attrs} end,
               git: fn ["-C", _, "status", "--porcelain"], [] -> {" M lib/file.ex\n", 0} end
             )
  end

  defp workspace(path), do: %{id: "workspace-1", name: "Native Workspace", path: path}

  defp environment(staging, checkout) do
    %{
      "CASEIN_API_TOKEN" => "secret-token",
      "CASEIN_AGENT_MCP_HOME" => staging,
      "CASEIN_CHECKOUT" => checkout,
      "CASEIN_TERMINAL_MCP_URL" => "http://127.0.0.1/api/terminals/mcp?workspace_id=workspace-1",
      "CASEIN_PREVIEW_MCP_URL" => "http://127.0.0.1/api/preview/mcp?workspace_id=workspace-1",
      "CASEIN_ARTIFACT_MCP_URL" => "http://127.0.0.1/api/artifacts/mcp?workspace_id=workspace-1"
    }
  end

  defp plan(path) do
    %NativeAgentLaunch{
      runtime: "codex",
      workspace_id: "workspace-1",
      worktree: %{path: path, primary: "C:/repo", branch: "agent/codex/task"}
    }
  end

  defp temp_root do
    root =
      Path.join(System.tmp_dir!(), "native-agent-launch-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    root
  end
end
