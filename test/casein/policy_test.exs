defmodule Casein.PolicyTest do
  use Casein.TestCase, async: false
  alias Casein.{Policy, Audit}
  alias Casein.Policy.{Decision, WorkspaceMode}
  alias Casein.Agents.Capability

  alias Casein.Workspaces

  setup do
    prev_default = Application.get_env(:casein, :default_workspace_mode)
    prev_overrides = Application.get_env(:casein, :workspace_modes)
    prev_raw_everywhere = Application.get_env(:casein, :raw_terminal_everywhere)

    Application.delete_env(:casein, :workspace_modes)
    Casein.Workspaces.State.MemoryAdapter.clear()

    on_exit(fn ->
      restore(:default_workspace_mode, prev_default)
      restore(:workspace_modes, prev_overrides)
      restore(:raw_terminal_everywhere, prev_raw_everywhere)
      Casein.Workspaces.State.MemoryAdapter.clear()
    end)

    :ok
  end

  defp restore(k, nil), do: Application.delete_env(:casein, k)
  defp restore(k, v), do: Application.put_env(:casein, k, v)

  test "default mode is :manual" do
    Application.delete_env(:casein, :default_workspace_mode)
    assert WorkspaceMode.resolve(nil) == :manual
  end

  test "per-workspace overrides win over default" do
    Application.put_env(:casein, :default_workspace_mode, :review)
    Application.put_env(:casein, :workspace_modes, %{"ws-1" => :shared_stage_guarded})
    assert WorkspaceMode.resolve("ws-1") == :shared_stage_guarded
    assert WorkspaceMode.resolve("ws-2") == :review
  end

  test "invalid mode in config falls back to :manual" do
    Application.put_env(:casein, :default_workspace_mode, :nonsense)
    assert WorkspaceMode.resolve(nil) == :manual
  end

  test "can_apply_proposal? denies a non-operator regardless of mode" do
    assert %Decision{verdict: :deny, reason: :forbidden} =
             Policy.can_apply_proposal?(%{workspace_id: "x"})
  end

  test "can_apply_proposal? requires :manual mode for an operator" do
    Application.put_env(:casein, :workspace_modes, %{"ws-review" => :review})

    assert %Decision{verdict: :deny, reason: :requires_manual_mode} =
             Policy.can_apply_proposal?(%{
               workspace_id: "ws-review",
               workspace_user: "alice",
               actor_username: "alice"
             })
  end

  test "can_apply_proposal? allows an operator in :manual mode" do
    Application.put_env(:casein, :workspace_modes, %{"ws-manual" => :manual})

    assert %Decision{verdict: :allow} =
             Policy.can_apply_proposal?(%{
               workspace_id: "ws-manual",
               workspace_user: "alice",
               actor_username: "alice"
             })
  end

  test "can_apply_proposal? denies shared-stage-guarded and unsafe-db workspaces even for an operator in :manual mode" do
    Application.put_env(:casein, :workspace_modes, %{"ws-manual" => :manual})

    ctx = %{
      workspace_id: "ws-manual",
      workspace_user: "alice",
      actor_username: "alice"
    }

    assert %Decision{verdict: :deny, reason: :unsafe_db} =
             Policy.can_apply_proposal?(Map.put(ctx, :db_isolation, :unsafe))

    assert %Decision{verdict: :deny, reason: :shared_stage_guarded} =
             Policy.can_apply_proposal?(Map.put(ctx, :db_isolation, :shared_stage))
  end

  test "can_enable_agent_write? denies with :agent_write_locked by default" do
    assert %Decision{verdict: :deny, reason: :agent_write_locked} =
             Policy.can_enable_agent_write?(%{workspace_id: "x"})
  end

  test "can_enable_agent_write? denies with :shared_stage_guarded for that mode" do
    Application.put_env(:casein, :workspace_modes, %{"ws-shared" => :shared_stage_guarded})

    assert %Decision{verdict: :deny, reason: :shared_stage_guarded} =
             Policy.can_enable_agent_write?(%{workspace_id: "ws-shared"})
  end

  test "can_enable_agent_write? requires :manual mode even with an active unlock" do
    Application.put_env(:casein, :workspace_modes, %{"ws-review" => :review})
    until = DateTime.add(DateTime.utc_now(), 3600, :second)
    {:ok, _} = Workspaces.grant_agent_write_unlock("ws-review", until, "alice")

    assert %Decision{verdict: :deny, reason: :requires_manual_mode} =
             Policy.can_enable_agent_write?(%{workspace_id: "ws-review"})
  end

  test "can_enable_agent_write? allows in :manual mode with an active unlock" do
    Application.put_env(:casein, :workspace_modes, %{"ws-unlocked" => :manual})
    until = DateTime.add(DateTime.utc_now(), 3600, :second)
    {:ok, _} = Workspaces.grant_agent_write_unlock("ws-unlocked", until, "alice")

    assert %Decision{verdict: :allow} =
             Policy.can_enable_agent_write?(%{workspace_id: "ws-unlocked"})
  end

  test "can_enable_agent_write? denies :agent_write_unlock_expired for a past unlock" do
    Application.put_env(:casein, :workspace_modes, %{"ws-expired" => :manual})
    past = DateTime.add(DateTime.utc_now(), -60, :second)
    {:ok, _} = Workspaces.grant_agent_write_unlock("ws-expired", past, "alice")

    assert %Decision{verdict: :deny, reason: :agent_write_unlock_expired} =
             Policy.can_enable_agent_write?(%{workspace_id: "ws-expired"})
  end

  test "can_enable_agent_write? denies :shared_stage_guarded even with an active unlock" do
    Application.put_env(:casein, :workspace_modes, %{
      "ws-shared-unlocked" => :shared_stage_guarded
    })

    until = DateTime.add(DateTime.utc_now(), 3600, :second)
    {:ok, _} = Workspaces.grant_agent_write_unlock("ws-shared-unlocked", until, "alice")

    assert %Decision{verdict: :deny, reason: :shared_stage_guarded} =
             Policy.can_enable_agent_write?(%{workspace_id: "ws-shared-unlocked"})
  end

  test "can_enable_agent_write? denies :unsafe_db even with an active unlock" do
    Application.put_env(:casein, :workspace_modes, %{"ws-unsafe" => :manual})
    until = DateTime.add(DateTime.utc_now(), 3600, :second)
    {:ok, _} = Workspaces.grant_agent_write_unlock("ws-unsafe", until, "alice")

    assert %Decision{verdict: :deny, reason: :unsafe_db} =
             Policy.can_enable_agent_write?(%{workspace_id: "ws-unsafe", db_isolation: :unsafe})
  end

  test "can_grant_agent_write_unlock? requires operator + :manual mode" do
    Application.put_env(:casein, :workspace_modes, %{
      "ws-manual" => :manual,
      "ws-review" => :review
    })

    assert %Decision{verdict: :deny, reason: :forbidden} =
             Policy.can_grant_agent_write_unlock?(%{workspace_id: "ws-manual"})

    assert %Decision{verdict: :deny, reason: :requires_manual_mode} =
             Policy.can_grant_agent_write_unlock?(%{
               workspace_id: "ws-review",
               workspace_user: "alice",
               actor_username: "alice"
             })

    assert %Decision{verdict: :allow} =
             Policy.can_grant_agent_write_unlock?(%{
               workspace_id: "ws-manual",
               workspace_user: "alice",
               actor_username: "alice"
             })
  end

  test "can_revoke_agent_write_unlock? is the kill switch: operator-only, no mode/isolation gate" do
    Application.put_env(:casein, :workspace_modes, %{"ws-review" => :review})

    assert %Decision{verdict: :deny, reason: :forbidden} =
             Policy.can_revoke_agent_write_unlock?(%{workspace_id: "ws-review"})

    # Non-manual mode and shared_stage_guarded/db isolation never block revoke.
    assert %Decision{verdict: :allow} =
             Policy.can_revoke_agent_write_unlock?(%{
               workspace_id: "ws-review",
               workspace_user: "alice",
               actor_username: "alice",
               db_isolation: :unsafe
             })
  end

  test "can_run_command? allows allowlisted ids for any authenticated peer" do
    owner_ctx = %{
      workspace_id: "x",
      command_id: "test",
      workspace_user: "alice",
      actor_username: "alice"
    }

    assert %Decision{verdict: :allow} = Policy.can_run_command?(owner_ctx)

    assert %Decision{verdict: :allow} =
             Policy.can_run_command?(%{
               workspace_id: "x",
               command_id: "test",
               workspace_user: "alice",
               actor_username: "bob"
             })

    assert %Decision{verdict: :allow} =
             Policy.can_run_command?(%{
               workspace_id: "x",
               command_id: "test",
               actor_username: "peer"
             })

    assert %Decision{verdict: :deny, reason: :not_allowed} =
             Policy.can_run_command?(%{
               workspace_id: "x",
               command_id: "rm -rf /",
               workspace_user: "alice",
               actor_username: "alice"
             })
  end

  test "can_use_raw_terminal? defaults to local manual workspace access only" do
    Application.put_env(:casein, :workspace_modes, %{
      "ws-manual" => :manual,
      "ws-review" => :review
    })

    assert %Decision{verdict: :deny, reason: :requires_manual_mode} =
             Policy.can_use_raw_terminal?(%{workspace_id: "ws-review", host_id: "local"})

    assert %Decision{verdict: :deny, reason: :requires_local_host} =
             Policy.can_use_raw_terminal?(%{workspace_id: "ws-manual", host_id: "remote"})

    assert %Decision{verdict: :allow} =
             Policy.can_use_raw_terminal?(%{workspace_id: "ws-manual", host_id: "local"})
  end

  test "can_use_raw_terminal? honors explicit raw everywhere opt-in" do
    Application.put_env(:casein, :raw_terminal_everywhere, true)

    assert %Decision{verdict: :allow} =
             Policy.can_use_raw_terminal?(%{workspace_id: "ws-review", host_id: "remote"})
  end

  test "can_run_command? denies agent triggers on unsafe DB isolation" do
    owner = %{workspace_user: "alice", actor_username: "alice"}

    assert %Decision{verdict: :deny, reason: :unsafe_db} =
             Policy.can_run_command?(
               Map.merge(owner, %{
                 workspace_id: "x",
                 command_id: "test",
                 actor_type: :agent,
                 db_isolation: :unsafe
               })
             )

    assert %Decision{verdict: :deny, reason: :shared_stage_guarded} =
             Policy.can_run_command?(
               Map.merge(owner, %{
                 workspace_id: "x",
                 command_id: "test",
                 actor_type: :agent,
                 db_isolation: :shared_stage
               })
             )

    assert %Decision{verdict: :allow} =
             Policy.can_run_command?(%{
               workspace_id: "x",
               command_id: "test",
               workspace_user: "alice",
               actor_username: "alice",
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

  test "can_set_workspace_mode? allows any authenticated peer when not config-pinned" do
    assert %Decision{verdict: :allow} =
             Policy.can_set_workspace_mode?(%{
               workspace_user: "alice",
               actor_username: "alice",
               workspace_mode_source: :default
             })

    assert %Decision{verdict: :allow} =
             Policy.can_set_workspace_mode?(%{
               workspace_user: "alice",
               actor_username: "bob",
               workspace_mode_source: :default
             })
  end

  test "workspace_role is operator for any authenticated actor (flat peer model)" do
    assert Policy.workspace_role(%{actor_username: "alice"}) == :operator
    assert Policy.workspace_role(%{actor_username: "bob", workspace_user: "alice"}) == :operator
    assert Policy.workspace_role(%{actor_id: "peer"}) == :operator
    assert Policy.workspace_role(%{}) == :viewer
  end

  test "can_set_workspace_mode? denies unauthenticated actor" do
    assert %Decision{verdict: :deny, reason: :forbidden} =
             Policy.can_set_workspace_mode?(%{
               workspace_user: "alice",
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

  test "can_edit_file? allows any authenticated peer in every mode" do
    owner_ctx = %{workspace_id: "ws", workspace_user: "alice", actor_username: "alice"}
    peer_ctx = %{workspace_id: "ws", workspace_user: "alice", actor_username: "bob"}
    empty_ctx = %{workspace_id: "ws", workspace_user: "alice"}

    for mode <- WorkspaceMode.valid_modes() do
      Application.put_env(:casein, :workspace_modes, %{"ws" => mode})
      assert %Decision{verdict: :allow} = Policy.can_edit_file?(owner_ctx)
      assert %Decision{verdict: :allow} = Policy.can_edit_file?(peer_ctx)
      assert %Decision{verdict: :deny, reason: :forbidden} = Policy.can_edit_file?(empty_ctx)
    end
  end

  test "Audit.emit_decision records policy.blocked for denials" do
    Audit.clear()
    deny = Policy.can_apply_proposal?(%{workspace_id: "ws-a"})
    Audit.emit_decision(deny, %{workspace_id: "ws-a", target_ref: "fix.diff"})

    [event] = Audit.recent_for("ws-a", 5)
    assert event.action == "policy.blocked"
    assert event.decision == :deny
    assert event.reason == :forbidden
    assert event.metadata.mode == :manual
  end

  test "Audit.emit_decision uses provided action for allow events" do
    Audit.clear()

    allow =
      Policy.can_run_command?(%{
        workspace_id: "ws-b",
        command_id: "test",
        workspace_user: "alice",
        actor_username: "alice"
      })

    Audit.emit_decision(allow, %{workspace_id: "ws-b", action: "command.started"})

    [event] = Audit.recent_for("ws-b", 5)
    assert event.action == "command.started"
    assert event.decision == :allow
  end
end
