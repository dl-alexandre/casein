defmodule DevIDE.PolicyTest do
  use ExUnit.Case, async: false
  alias DevIDE.{Policy, Audit}
  alias DevIDE.Policy.{Decision, WorkspaceMode}
  alias DevIDE.Agents.Capability

  setup do
    prev_default = Application.get_env(:dev_ide, :default_workspace_mode)
    prev_overrides = Application.get_env(:dev_ide, :workspace_modes)

    Application.delete_env(:dev_ide, :workspace_modes)

    on_exit(fn ->
      restore(:default_workspace_mode, prev_default)
      restore(:workspace_modes, prev_overrides)
    end)

    :ok
  end

  defp restore(k, nil), do: Application.delete_env(:dev_ide, k)
  defp restore(k, v), do: Application.put_env(:dev_ide, k, v)

  test "default mode is :review" do
    Application.delete_env(:dev_ide, :default_workspace_mode)
    assert WorkspaceMode.resolve(nil) == :review
  end

  test "per-workspace overrides win over default" do
    Application.put_env(:dev_ide, :default_workspace_mode, :review)
    Application.put_env(:dev_ide, :workspace_modes, %{"ws-1" => :shared_stage_guarded})
    assert WorkspaceMode.resolve("ws-1") == :shared_stage_guarded
    assert WorkspaceMode.resolve("ws-2") == :review
  end

  test "invalid mode in config falls back to :review" do
    Application.put_env(:dev_ide, :default_workspace_mode, :nonsense)
    assert WorkspaceMode.resolve(nil) == :review
  end

  test "can_apply_proposal? is always denied with :not_implemented" do
    assert %Decision{verdict: :deny, reason: :not_implemented} =
             Policy.can_apply_proposal?(%{workspace_id: "x"})
  end

  test "can_enable_agent_write? denies with :agent_write_locked by default" do
    assert %Decision{verdict: :deny, reason: :agent_write_locked} =
             Policy.can_enable_agent_write?(%{workspace_id: "x"})
  end

  test "can_run_loop? denies unless Loops enabled in config" do
    prev = Application.get_env(:dev_ide, DevIDE.Loops)
    Application.put_env(:dev_ide, DevIDE.Loops, enabled: false)

    assert %Decision{verdict: :deny, reason: :not_allowed} = Policy.can_run_loop?(%{})

    Application.put_env(:dev_ide, DevIDE.Loops, enabled: true)
    assert %Decision{verdict: :allow} = Policy.can_run_loop?(%{})

    case prev do
      nil -> Application.delete_env(:dev_ide, DevIDE.Loops)
      val -> Application.put_env(:dev_ide, DevIDE.Loops, val)
    end
  end

  test "can_enable_agent_write? denies with :shared_stage_guarded for that mode" do
    Application.put_env(:dev_ide, :workspace_modes, %{"ws-shared" => :shared_stage_guarded})

    assert %Decision{verdict: :deny, reason: :shared_stage_guarded} =
             Policy.can_enable_agent_write?(%{workspace_id: "ws-shared"})
  end

  test "can_run_command? allows allowlisted ids and denies others" do
    assert %Decision{verdict: :allow} =
             Policy.can_run_command?(%{workspace_id: "x", command_id: "test"})

    assert %Decision{verdict: :deny, reason: :not_allowed} =
             Policy.can_run_command?(%{workspace_id: "x", command_id: "rm -rf /"})
  end

  test "can_run_command? denies agent triggers on unsafe DB isolation" do
    assert %Decision{verdict: :deny, reason: :unsafe_db} =
             Policy.can_run_command?(%{
               workspace_id: "x",
               command_id: "test",
               actor_type: :agent,
               db_isolation: :unsafe
             })

    assert %Decision{verdict: :deny, reason: :shared_stage_guarded} =
             Policy.can_run_command?(%{
               workspace_id: "x",
               command_id: "test",
               actor_type: :agent,
               db_isolation: :shared_stage
             })

    assert %Decision{verdict: :allow} =
             Policy.can_run_command?(%{
               workspace_id: "x",
               command_id: "test",
               db_isolation: :unsafe
             })
  end

  test "can_start_review_agent? requires capability and allowlisted id" do
    deny =
      Policy.can_start_review_agent?(%{
        workspace_id: "x",
        agent_run_id: "opencode-version",
        caps: []
      })

    assert deny.verdict == :deny and deny.reason == :requires_not_met

    allow =
      Policy.can_start_review_agent?(%{
        workspace_id: "x",
        agent_run_id: "opencode-version",
        caps: [%Capability{kind: :opencode, status: :detected}]
      })

    assert allow.verdict == :allow

    bad =
      Policy.can_start_review_agent?(%{workspace_id: "x", agent_run_id: "nope", caps: []})

    assert bad.verdict == :deny and bad.reason == :not_allowed
  end

  test "can_set_workspace_mode? allows owner when not config-pinned" do
    assert %Decision{verdict: :allow} =
             Policy.can_set_workspace_mode?(%{
               workspace_user: "alice",
               actor_username: "alice",
               workspace_mode_source: :default
             })
  end

  test "can_set_workspace_mode? allows admins and operators" do
    for role <- [:admin, "operator"] do
      assert %Decision{verdict: :allow} =
               Policy.can_set_workspace_mode?(%{
                 workspace_user: "alice",
                 actor_username: "bob",
                 actor_role: role,
                 workspace_mode_source: :default
               })
    end
  end

  test "workspace_role resolves operator, owner, and viewer" do
    assert Policy.workspace_role(%{actor_role: :admin}) == :operator
    assert Policy.workspace_role(%{workspace_user: "alice", actor_username: "alice"}) == :owner
    assert Policy.workspace_role(%{workspace_user: "alice", actor_username: "bob"}) == :viewer
  end

  test "can_set_workspace_mode? denies non-owner" do
    assert %Decision{verdict: :deny, reason: :forbidden} =
             Policy.can_set_workspace_mode?(%{
               workspace_user: "alice",
               actor_username: "bob",
               workspace_mode_source: :default
             })
  end

  test "can_set_workspace_mode? denies when mode is config-pinned" do
    assert %Decision{verdict: :deny, reason: :config_override} =
             Policy.can_set_workspace_mode?(%{
               workspace_user: "alice",
               actor_username: "alice",
               workspace_mode_source: :config
             })
  end

  test "can_edit_file? allows in every mode" do
    for mode <- WorkspaceMode.valid_modes() do
      Application.put_env(:dev_ide, :workspace_modes, %{"ws" => mode})
      assert %Decision{verdict: :allow} = Policy.can_edit_file?(%{workspace_id: "ws"})
    end
  end

  test "Audit.emit_decision records policy.blocked for denials" do
    Audit.clear()
    deny = Policy.can_apply_proposal?(%{workspace_id: "ws-a"})
    Audit.emit_decision(deny, %{workspace_id: "ws-a", target_ref: "fix.diff"})

    [event] = Audit.recent_for("ws-a", 5)
    assert event.action == "policy.blocked"
    assert event.decision == :deny
    assert event.reason == :not_implemented
    assert event.metadata.mode == :review
  end

  test "Audit.emit_decision uses provided action for allow events" do
    Audit.clear()
    allow = Policy.can_run_command?(%{workspace_id: "ws-b", command_id: "test"})
    Audit.emit_decision(allow, %{workspace_id: "ws-b", action: "command.started"})

    [event] = Audit.recent_for("ws-b", 5)
    assert event.action == "command.started"
    assert event.decision == :allow
  end
end
