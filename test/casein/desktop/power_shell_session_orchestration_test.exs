defmodule Casein.Desktop.PowerShellSessionOrchestrationTest do
  use ExUnit.Case, async: true

  alias Casein.Desktop.{NativeAgentLaunch, PowerShellSession}

  test "launches through the retained transaction and returns agent topology" do
    workspace = %{id: "workspace-1", name: "Native Workspace", path: "C:/repo"}
    plan = plan(workspace)
    parent = self()

    assert {:ok, %{plan: ^plan, topology: %{panes: [%{role: "agent"}]}}} =
             PowerShellSession.launch_agent(workspace, "codex", "ticket-462",
               launch_opts: [prepare_opts: [worktree_opts: [base_ref: "origin/master"]]],
               launcher: fn ^workspace, "codex", "ticket-462", launch_opts ->
                 send(parent, {:launched, launch_opts})
                 {:ok, plan}
               end,
               topology_reporter: fn ^workspace ->
                 {:ok, %{panes: [%{role: "agent"}]}}
               end
             )

    assert_receive {:launched, [prepare_opts: [worktree_opts: [base_ref: "origin/master"]]]}
  end

  test "records a handoff when topology reporting fails after launch" do
    workspace = %{id: "workspace-1", name: "Native Workspace", path: "C:/repo"}
    plan = plan(workspace)
    parent = self()

    assert {:error, :session_unavailable} =
             PowerShellSession.launch_agent(workspace, "claude", "ticket-462",
               launcher: fn _, _, _, _ -> {:ok, plan} end,
               topology_reporter: fn _ ->
                 {:topology_error, :session_unavailable}
               end,
               finish_opts: [reporter: :native],
               finisher: fn ^plan, "handoff", handoff, finish_opts ->
                 send(parent, {:handoff, handoff, finish_opts})
                 {:ok, %{removed: false}}
               end
             )

    assert_receive {:handoff, "native claude topology reporting failed", [reporter: :native]}
  end

  test "does not report a handoff when the launch transaction fails" do
    assert {:error, :authentication_not_detected} =
             PowerShellSession.launch_agent(%{id: "workspace-1"}, "grok", "ticket-462",
               launcher: fn _, _, _, _ -> {:error, :authentication_not_detected} end,
               topology_reporter: fn _ -> flunk("topology must not be requested") end,
               finisher: fn _, _, _, _ -> flunk("handoff belongs to the launch transaction") end
             )
  end

  defp plan(workspace) do
    %NativeAgentLaunch{
      runtime: "codex",
      workspace: workspace,
      workspace_id: workspace.id,
      command: "codex\r",
      worktree: %{
        path: "C:/worktrees/launch",
        primary: workspace.path,
        branch: "agent/codex/ticket-462"
      }
    }
  end
end
