defmodule Casein.Export.WorkspaceStatusTest do
  use Casein.TestCase, async: false

  alias Casein.Agents.Activity
  alias Casein.Audit
  alias Casein.Export.WorkspaceStatus
  alias Casein.Runs.Ledger
  alias Casein.Workspace
  alias Casein.Workspaces.State
  alias Casein.Workspaces.State.MemoryAdapter

  setup do
    prev_tmux_adapter = Application.get_env(:casein, :tmux_adapter)
    prev_fake_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
    prev_fake_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)
    prev_fake_session_meta = TmuxCtl.Test.FakeState.get(:fake_tmux_session_meta)

    MemoryAdapter.clear()
    Audit.clear()
    Activity.clear()
    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)

    on_exit(fn ->
      MemoryAdapter.clear()
      Audit.clear()
      Activity.clear()
      restore_app_env(:tmux_adapter, prev_tmux_adapter)
      restore_fake_state(:fake_tmux_windows, prev_fake_windows)
      restore_fake_state(:fake_tmux_panes, prev_fake_panes)
      restore_fake_state(:fake_tmux_session_meta, prev_fake_session_meta)
    end)

    {:ok, _} =
      State.sync(%Workspace{
        id: "ws-deploy",
        name: "deploy-test",
        user: "alice",
        branch: "main",
        status: :running,
        path: nil,
        metadata: %{}
      })

    :ok
  end

  test "status includes deploy summary from deployment health" do
    assert {:ok, payload} = WorkspaceStatus.status("ws-deploy")
    assert is_map(payload.deploy)
    assert is_binary(payload.deploy.running_revision)
    assert is_boolean(payload.deploy.ok)
    assert is_map(payload.deploy.checks)
    assert Map.has_key?(payload.deploy.checks, :deploy_revision_current)

    assert %{
             status: "no_sessions",
             ready: false,
             required_role: "agent",
             suggested_template: "agent_pair",
             auto_apply_option: "auto_apply_agent_pair",
             sessions_checked: 0,
             agent_panes: [],
             candidate_sessions: []
           } = payload.agent_layout
  end

  test "status includes preview_environments list and tidewave_mcp_url field" do
    assert {:ok, payload} = WorkspaceStatus.status("ws-deploy")
    assert is_list(payload.preview_environments)
    assert Map.has_key?(payload, :tidewave_mcp_url)
  end

  test "status includes compact agent session prompt state" do
    tmux_session = Casein.Terminals.Tmux.session_name("deploy-test", "agent")

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      tmux_session => [
        %{id: "@1", index: 0, name: "agent", active: true, panes: 1, activity: 42}
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      tmux_session => [
        %{
          id: "%4",
          window_id: "@1",
          index: 0,
          active: true,
          left: 0,
          top: 0,
          width: 120,
          height: 40,
          current_command: "codex",
          current_path: "/workspace",
          role: "agent"
        }
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_session_meta, %{
      tmux_session => %{session_alias: "Fix deploy preview"}
    })

    Activity.record(%{
      workspace_id: "ws-deploy",
      source: :terminal_mcp,
      tool: "send_agent_prompt",
      summary: "done: Fix deploy preview",
      status: :ok,
      metadata: %{
        "session" => tmux_session,
        "pane" => "%4",
        "status" => "done",
        "title" => "Fix deploy preview",
        "prompt_excerpt" => "Bearer secret-token"
      }
    })

    assert {:ok, payload} = WorkspaceStatus.status("ws-deploy")

    assert [
             %{
               id: "agent",
               label: "Fix deploy preview",
               title: "Fix deploy preview",
               status: "done",
               tmux_session: ^tmux_session,
               pane: "%4",
               preview_pane_ids: []
             }
           ] = payload.agent_sessions

    refute inspect(payload.agent_sessions) =~ "secret-token"
    refute inspect(payload.agent_sessions) =~ "prompt_excerpt"

    assert %{
             status: "ready",
             ready: true,
             required_role: "agent",
             suggested_template: "agent_pair",
             auto_apply_option: "auto_apply_agent_pair",
             sessions_checked: 1,
             agent_panes: [
               %{
                 id: "%4",
                 window_id: "@1",
                 index: 0,
                 active: true,
                 current_command: "codex",
                 role: "agent"
               }
             ],
             candidate_sessions: [layout_session]
           } = payload.agent_layout

    assert layout_session.tmux_session == tmux_session
    assert layout_session.status == "ready"
    assert layout_session.pane_count == 1
    refute inspect(payload.agent_layout) =~ "/workspace"
  end

  test "status includes layout guidance when sessions lack an agent pane" do
    tmux_session = Casein.Terminals.Tmux.session_name("deploy-test", "agent")

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      tmux_session => [
        %{id: "@1", index: 0, name: "work", active: true, panes: 1, activity: 42}
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      tmux_session => [
        %{
          id: "%4",
          window_id: "@1",
          index: 0,
          active: true,
          left: 0,
          top: 0,
          width: 120,
          height: 40,
          current_command: "bash",
          current_path: "/workspace",
          role: "operator"
        }
      ]
    })

    assert {:ok, payload} = WorkspaceStatus.status("ws-deploy")

    assert %{
             status: "missing_agent_pane",
             ready: false,
             required_role: "agent",
             suggested_template: "agent_pair",
             auto_apply_option: "auto_apply_agent_pair",
             sessions_checked: 1,
             agent_panes: [],
             candidate_sessions: [
               %{
                 tmux_session: ^tmux_session,
                 status: "missing_agent_pane",
                 pane_count: 1,
                 candidate_panes: [
                   %{
                     id: "%4",
                     window_id: "@1",
                     index: 0,
                     active: true,
                     current_command: "bash",
                     role: "operator"
                   }
                 ]
               }
             ]
           } = payload.agent_layout

    refute inspect(payload.agent_layout) =~ "/workspace"
  end

  test "previous_sessions preserves safe preview context while scrubbing secrets" do
    Activity.record(%{
      workspace_id: "ws-deploy",
      source: :preview_mcp,
      tool: "preview_screenshot",
      summary: "preview_screenshot snap.png",
      status: :ok,
      metadata: %{
        "agent_session" => "casein_alpha_agent",
        "agent_pane" => "%2",
        "session_id" => "preview-123",
        "pane_id" => "%8",
        "preview_title" => "Deploy Dashboard",
        "preview_status" => "ready",
        "url" => "http://localhost:4000/dashboard?token=secret-token",
        "source_url" => "http://localhost:4000/source?token=secret-token",
        "display_url" => "/preview-proxy/ws-deploy/4000/dashboard",
        "screenshot_url" => "/preview-artifacts/ws-deploy/snap.png",
        "recording_id" => "rec-export",
        "recording_url" => "/preview-artifacts/ws-deploy/rec.webm?token=secret-token",
        "recording_path" => "/preview-artifacts/ws-deploy/rec.webm",
        "recording_status" => "recorded",
        "token" => "secret-token"
      }
    })

    assert {:ok, %{results: [result]}} =
             WorkspaceStatus.previous_sessions("ws-deploy",
               query: "snap.png",
               source: "preview"
             )

    assert result.session == "preview-123"
    assert result.pane == "%8"
    assert result.href == "/workspaces/ws-deploy"

    assert result.preview.agent_action == "preview_screenshot"
    assert result.preview.agent_session == "casein_alpha_agent"
    assert result.preview.agent_pane == "%2"
    assert result.preview.session_id == "preview-123"
    assert result.preview.pane == "%8"
    assert result.preview.title == "Deploy Dashboard"
    assert result.preview.status == "ready"
    assert result.preview.display_url == "/preview-proxy/ws-deploy/4000/dashboard"
    assert result.preview.screenshot_url == "/preview-artifacts/ws-deploy/snap.png"
    assert result.preview.recording_id == "rec-export"

    assert result.preview.recording_url ==
             "/preview-artifacts/ws-deploy/rec.webm?token=[REDACTED]"

    assert result.preview.recording_path == "/preview-artifacts/ws-deploy/rec.webm"
    assert result.preview.recording_status == "recorded"
    assert result.preview.url == "http://localhost:4000/dashboard?token=[REDACTED]"
    assert result.preview.source_url == "http://localhost:4000/source?token=[REDACTED]"

    refute Map.has_key?(result.metadata, "session_id")
    refute Map.has_key?(result.metadata, "token")
    refute inspect(result) =~ "secret-token"
  end

  test "status returns :error for unknown workspace" do
    assert WorkspaceStatus.status("missing-workspace") == :error
    assert WorkspaceStatus.status(nil) == :error
  end

  test "list_summary returns synced workspace summaries" do
    summaries = WorkspaceStatus.list_summary()
    assert [%{id: "ws-deploy", name: "deploy-test"} | _] = summaries
  end

  test "deploy summary includes socket fields from health status" do
    assert {:ok, payload} = WorkspaceStatus.status("ws-deploy")
    assert Map.has_key?(payload.deploy, :socket_path)
    assert Map.has_key?(payload.deploy, :current_socket)
  end

  test "runs/1 returns ledger-backed run summaries" do
    run_id = seed_run!()

    assert {:ok, runs} = WorkspaceStatus.runs("ws-deploy")
    assert [%{id: ^run_id, command_id: "format", status: "succeeded"} | _] = runs
    assert WorkspaceStatus.runs("missing") == :error
  end

  test "run/2 returns timeline and scrubbed summary" do
    run_id = seed_run!()

    assert {:ok, payload} = WorkspaceStatus.run("ws-deploy", run_id)
    assert payload.id == run_id
    assert payload.workspace_id == "ws-deploy"
    assert payload.summary.command_id == "format"

    assert Enum.map(payload.timeline, & &1.action) == [
             "run.started",
             "run.succeeded"
           ]

    assert payload.artifacts == []
    assert WorkspaceStatus.run("ws-deploy", "missing-run") == :error
  end

  test "proposals/1 returns an empty list without host_path and discovers files when present" do
    assert {:ok, []} = WorkspaceStatus.proposals("ws-deploy")

    root = proposal_root!()

    {:ok, _} =
      State.sync(%Workspace{
        id: "ws-proposals",
        name: "proposals-test",
        user: "alice",
        branch: "main",
        status: :running,
        path: root,
        metadata: %{}
      })

    base = Path.join([root, ".opencode", "proposals"])
    File.mkdir_p!(base)
    File.write!(Path.join(base, "fix.diff"), "--- a/x\n+++ b/x\n")

    assert {:ok, [%{path: ".opencode/proposals/fix.diff"} | _]} =
             WorkspaceStatus.proposals("ws-proposals")

    assert WorkspaceStatus.proposals("missing") == :error
  end

  test "audit/1 returns recent audit events with ledger metadata" do
    {:ok, event} =
      Audit.emit(%{
        workspace_id: "ws-deploy",
        actor_id: "agent-1",
        action: "terminal.command_sent",
        target_type: "tmux_session",
        target_ref: "casein_alpha_main"
      })

    assert {:ok, [audit_entry | _]} = WorkspaceStatus.audit("ws-deploy")
    assert audit_entry.id == event.id
    assert audit_entry.action == "terminal.command_sent"
    assert audit_entry.inserted_at
    assert WorkspaceStatus.audit("missing") == :error
  end

  defp seed_run! do
    run_id = Ledger.new_run_id()

    Ledger.run_started(%{
      workspace_id: "ws-deploy",
      actor_id: "dev",
      command_id: "format",
      run_id: run_id
    })

    Ledger.run_finished(:succeeded, %{
      workspace_id: "ws-deploy",
      actor_id: "dev",
      command_id: "format",
      run_id: run_id,
      metadata: %{exit_code: 0}
    })

    run_id
  end

  defp proposal_root! do
    root =
      Path.join(System.tmp_dir!(), "ws-status-proposals-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:casein, key)
  defp restore_app_env(key, value), do: Application.put_env(:casein, key, value)

  defp restore_fake_state(key, nil), do: TmuxCtl.Test.FakeState.delete(key)
  defp restore_fake_state(key, value), do: TmuxCtl.Test.FakeState.put(key, value)
end
