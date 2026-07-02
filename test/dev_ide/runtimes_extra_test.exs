defmodule DevIDE.RuntimesExtraTest do
  use DevIDE.TestCase, async: false

  alias DevIDE.Workspace
  alias DevIDE.Runtimes
  alias DevIDE.Runtimes.LifecycleEvent
  alias DevIDE.Runtimes.WorktreeReconciler
  alias DevIDE.Test.RuntimeSeed
  alias DevIDE.Workspaces.DbIsolation
  alias DevIDE.Workspaces.State
  alias DevIDE.Workspaces.State.MemoryAdapter

  setup do
    MemoryAdapter.clear()
    Runtimes.clear()
    WorktreeReconciler.clear()
    DevIDE.Audit.MemoryAdapter.clear()

    prev_runtime = Application.get_env(:dev_ide, :runtimes_adapter)

    Application.put_env(:dev_ide, :runtimes_adapter, DevIDE.Runtimes.MemoryAdapter)

    on_exit(fn ->
      MemoryAdapter.clear()
      Runtimes.clear()
      WorktreeReconciler.clear()
      DevIDE.Audit.MemoryAdapter.clear()
      restore_env(:runtimes_adapter, prev_runtime)
    end)

    seed_workspace("ws-runtime")
    :ok
  end

  # ---- get_runtime/1 guards ----

  test "get_runtime returns :error for non-binary ids" do
    assert Runtimes.get_runtime(nil) == :error
    assert Runtimes.get_runtime(123) == :error
    assert Runtimes.get_runtime(%{}) == :error
  end

  test "get_runtime returns :error for an unknown binary id" do
    assert Runtimes.get_runtime("rt-does-not-exist") == :error
  end

  # ---- events_for/1 guards ----

  test "events_for returns [] for non-binary ids" do
    assert Runtimes.events_for(nil) == []
    assert Runtimes.events_for(123) == []
  end

  test "events_for returns the seeded lifecycle event for a known id" do
    {:ok, runtime} = RuntimeSeed.seed_runtime("ws-runtime", runtime_id: "rt-events")
    events = Runtimes.events_for(runtime.id)
    assert Enum.map(events, & &1.event) == ["runtime_requested"]
  end

  # ---- list_agent_worktrees/1 guard ----

  test "list_agent_worktrees returns [] for non-binary workspace ids" do
    assert Runtimes.list_agent_worktrees(nil) == []
    assert Runtimes.list_agent_worktrees(123) == []
  end

  test "list_agent_worktrees excludes non-agent and cleaned/expired runtimes" do
    # Plain runtime (no agent_worktree metadata) is filtered out.
    {:ok, _plain} =
      RuntimeSeed.seed_runtime("ws-runtime", runtime_id: "rt-plain", status: "provisioned")

    # Agent worktree runtime that is active -> included.
    {:ok, _active} =
      RuntimeSeed.seed_runtime("ws-runtime",
        runtime_id: "rt-agent-active",
        status: "provisioned",
        worktree_path: "/tmp/ws-runtime/agent-active",
        branch: "feature/x",
        tmux_session_id: "devide_active",
        metadata: %{
          "kind" => "agent_worktree",
          "agent" => "codex",
          "source" => "agent_report",
          "git_toplevel" => "/tmp/ws-runtime/agent-active",
          "git_common_dir" => "/tmp/ws-runtime/.git",
          "git_head_sha" => "abc123",
          "git_detached" => false
        }
      )

    # Agent worktree runtime that is expired -> excluded.
    {:ok, _expired} =
      RuntimeSeed.seed_runtime("ws-runtime",
        runtime_id: "rt-agent-expired",
        status: "expired",
        worktree_path: "/tmp/ws-runtime/agent-expired",
        metadata: %{"provisioning_model" => "agent_worktree"}
      )

    payloads = Runtimes.list_agent_worktrees("ws-runtime")
    assert [payload] = payloads
    assert payload.runtime_id == "rt-agent-active"
    assert payload.path == "/tmp/ws-runtime/agent-active"
    assert payload.path_label == "agent-active"
    assert payload.branch == "feature/x"
    assert payload.tmux_session_id == "devide_active"
    assert payload.git_common_dir == "/tmp/ws-runtime/.git"
    assert payload.git_head_sha == "abc123"
    assert payload.agent == "codex"
    assert payload.source == "agent_report"
    # git_detached false is kept (only nil/"" rejected); path_label derives basename.
    assert payload.git_detached? == false
  end

  test "agent_worktree_payload falls back to metadata worktree_path and rejects nil fields" do
    {:ok, _runtime} =
      RuntimeSeed.seed_runtime("ws-runtime",
        runtime_id: "rt-agent-meta",
        status: "provisioned",
        metadata: %{
          "kind" => "agent_worktree",
          "worktree_path" => "/tmp/ws-runtime/meta-path"
        }
      )

    assert [payload] = Runtimes.list_agent_worktrees("ws-runtime")
    assert payload.path == "/tmp/ws-runtime/meta-path"
    assert payload.path_label == "meta-path"
    # git_toplevel falls back to the path when metadata lacks one.
    assert payload.git_toplevel == "/tmp/ws-runtime/meta-path"
    # Absent optional keys are dropped, not set to nil.
    refute Map.has_key?(payload, :agent)
    refute Map.has_key?(payload, :branch)
  end

  # ---- observe_worktree/2 invalid attrs ----

  test "observe_worktree rejects invalid attrs argument shapes" do
    assert Runtimes.observe_worktree("ws-runtime", "not-a-map") == {:error, :invalid_attrs}
    assert Runtimes.observe_worktree(123, %{}) == {:error, :invalid_attrs}
    assert Runtimes.observe_worktree(nil, %{}) == {:error, :invalid_attrs}
  end

  test "observe_worktree requires a worktree path attr" do
    assert {:error, :worktree_path_required} =
             Runtimes.observe_worktree("ws-runtime", %{"agent" => "codex"})
  end

  test "observe_worktree reports worktree_not_found for a missing directory" do
    missing = "/tmp/ws-runtime/missing-#{System.unique_integer([:positive])}"

    assert {:error, :worktree_not_found} =
             Runtimes.observe_worktree("ws-runtime", %{"worktree_path" => missing})
  end

  # ---- discover_worktrees/1 guard ----

  test "discover_worktrees rejects non-binary workspace ids" do
    assert Runtimes.discover_worktrees(nil) == {:error, :invalid_workspace_id}
    assert Runtimes.discover_worktrees(123) == {:error, :invalid_workspace_id}
  end

  test "discover_worktrees returns empty result for an unknown workspace" do
    # State.get returns :error -> falls into the :error -> empty result branch.
    assert {:ok, %{observed: [], expired: [], rejected: []}} =
             Runtimes.discover_worktrees("ws-not-seeded")
  end

  # ---- expire_runtime / cleanup_runtime ----

  test "expire_runtime returns :error for an unknown runtime" do
    assert Runtimes.expire_runtime("rt-unknown") == :error
  end

  test "expire_runtime transitions a provisioned runtime to expired with reason" do
    {:ok, runtime} =
      RuntimeSeed.seed_runtime("ws-runtime", runtime_id: "rt-expire", status: "provisioned")

    assert {:ok, expired} =
             Runtimes.expire_runtime(runtime.id, %{"reason" => "stale_runtime"})

    assert expired.status == "expired"
    assert expired.failure_reason == "stale_runtime"
    assert %DateTime{} = expired.expired_at
    # heartbeat_at preserved (was set by seed) or defaulted.
    assert %DateTime{} = expired.heartbeat_at
  end

  test "expire_runtime accepts an explicit expired_at iso8601 string" do
    {:ok, runtime} =
      RuntimeSeed.seed_runtime("ws-runtime", runtime_id: "rt-expire-at", status: "provisioned")

    when_str = "2026-01-02T03:04:05Z"

    assert {:ok, expired} =
             Runtimes.expire_runtime(runtime.id, %{"expired_at" => when_str})

    assert DateTime.to_iso8601(expired.expired_at) == when_str
  end

  test "expire_runtime errors when the runtime is in a terminal state" do
    {:ok, runtime} =
      RuntimeSeed.seed_runtime("ws-runtime", runtime_id: "rt-terminal", status: "cleaned")

    assert {:error, :runtime_terminal} = Runtimes.expire_runtime(runtime.id)
  end

  test "cleanup_runtime returns :error for an unknown runtime" do
    assert Runtimes.cleanup_runtime("rt-unknown") == :error
  end

  test "cleanup_runtime marks an expired runtime cleaned and zeroes assignments" do
    {:ok, runtime} =
      RuntimeSeed.seed_runtime("ws-runtime",
        runtime_id: "rt-cleanup",
        status: "expired",
        active_assignments: 3
      )

    assert {:ok, cleaned} = Runtimes.cleanup_runtime(runtime.id)
    assert cleaned.status == "cleaned"
    assert cleaned.active_assignments == 0
    assert %DateTime{} = cleaned.cleaned_at
  end

  test "cleanup_runtime can transition directly from provisioned" do
    {:ok, runtime} =
      RuntimeSeed.seed_runtime("ws-runtime", runtime_id: "rt-prov-clean", status: "provisioned")

    assert {:ok, cleaned} =
             Runtimes.cleanup_runtime(runtime.id, %{"cleaned_at" => "2026-02-03T04:05:06Z"})

    assert cleaned.status == "cleaned"
    assert DateTime.to_iso8601(cleaned.cleaned_at) == "2026-02-03T04:05:06Z"
  end

  test "cleanup_runtime errors when the runtime is requested (invalid transition)" do
    {:ok, runtime} =
      RuntimeSeed.seed_runtime("ws-runtime", runtime_id: "rt-requested", status: "requested")

    assert {:error, :invalid_runtime_transition} = Runtimes.cleanup_runtime(runtime.id)
  end

  # ---- expire_stale / cleanup_expired ----

  test "expire_stale expires runtimes older than the ttl and skips terminal ones" do
    now = ~U[2026-06-24 00:00:00Z]
    old = DateTime.add(now, -7200, :second)

    {:ok, _stale} =
      RuntimeSeed.seed_runtime("ws-runtime",
        runtime_id: "rt-stale",
        status: "provisioned",
        created_at: old,
        heartbeat_at: old
      )

    {:ok, _fresh} =
      RuntimeSeed.seed_runtime("ws-runtime",
        runtime_id: "rt-fresh",
        status: "provisioned",
        created_at: now,
        heartbeat_at: now
      )

    {:ok, _cleaned} =
      RuntimeSeed.seed_runtime("ws-runtime",
        runtime_id: "rt-cleaned",
        status: "cleaned",
        created_at: old,
        heartbeat_at: old
      )

    expired = Runtimes.expire_stale(now, ttl_seconds: 3600)
    ids = Enum.map(expired, & &1.id)

    assert ids == ["rt-stale"]
    assert hd(expired).status == "expired"
    assert hd(expired).failure_reason == "stale_runtime"
  end

  test "cleanup_expired cleans every currently expired runtime" do
    {:ok, _a} =
      RuntimeSeed.seed_runtime("ws-runtime", runtime_id: "rt-exp-a", status: "expired")

    {:ok, _b} =
      RuntimeSeed.seed_runtime("ws-runtime", runtime_id: "rt-exp-b", status: "expired")

    {:ok, _prov} =
      RuntimeSeed.seed_runtime("ws-runtime", runtime_id: "rt-prov", status: "provisioned")

    cleaned = Runtimes.cleanup_expired()
    ids = cleaned |> Enum.map(& &1.id) |> Enum.sort()

    assert ids == ["rt-exp-a", "rt-exp-b"]
    assert Enum.all?(cleaned, &(&1.status == "cleaned"))
  end

  # ---- decorate_assignment_metadata / runtime_id_from_metadata ----

  test "decorate_assignment_metadata returns non-map metadata unchanged" do
    assert Runtimes.decorate_assignment_metadata("nope") == "nope"
    assert Runtimes.decorate_assignment_metadata(nil) == nil
  end

  test "decorate_assignment_metadata returns metadata unchanged when no runtime id present" do
    metadata = %{"foo" => "bar"}
    assert Runtimes.decorate_assignment_metadata(metadata) == metadata
  end

  test "decorate_assignment_metadata returns metadata unchanged when runtime id is unknown" do
    metadata = %{"runtime_id" => "rt-missing"}
    assert Runtimes.decorate_assignment_metadata(metadata) == metadata
  end

  test "runtime_id_from_metadata resolves ids from each accepted location" do
    assert Runtimes.runtime_id_from_metadata(%{"runtime" => %{"id" => "rt-1"}}) == "rt-1"
    assert Runtimes.runtime_id_from_metadata(%{"runtime" => %{"runtime_id" => "rt-2"}}) == "rt-2"
    assert Runtimes.runtime_id_from_metadata(%{"runtime_id" => "rt-3"}) == "rt-3"
    assert Runtimes.runtime_id_from_metadata(%{"runtime" => "rt-4"}) == "rt-4"
    assert Runtimes.runtime_id_from_metadata(%{"other" => "x"}) == nil
  end

  test "runtime_id_from_metadata accepts atom-keyed runtime map" do
    assert Runtimes.runtime_id_from_metadata(%{runtime: %{"id" => "rt-atom"}}) == "rt-atom"
  end

  test "runtime_id_from_metadata returns nil for non-map input" do
    assert Runtimes.runtime_id_from_metadata("x") == nil
    assert Runtimes.runtime_id_from_metadata(nil) == nil
  end

  # ---- mark_preview_server/3 guard ----

  test "mark_preview_server rejects non-runtime arguments" do
    assert Runtimes.mark_preview_server(%{}, "starting") == {:error, :invalid_runtime}
    assert Runtimes.mark_preview_server(nil, "starting") == {:error, :invalid_runtime}
  end

  # ---- payload/1 ----

  test "payload projects runtime fields and iso-formats timestamps" do
    created = ~U[2026-06-01 12:00:00Z]

    {:ok, runtime} =
      RuntimeSeed.seed_runtime("ws-runtime",
        runtime_id: "rt-payload",
        host_id: "host-z",
        os: "linux",
        repo: "onebackend-v3",
        branch: "main",
        worktree_path: "/tmp/ws-runtime/payload",
        runner_id: "runner-7",
        session_id: "sess-7",
        tmux_session_id: "devide_payload",
        status: "provisioned",
        capabilities: ["git"],
        tools: ["mix"],
        concurrency_limit: 2,
        active_assignments: 1,
        created_at: created,
        heartbeat_at: created
      )

    payload = Runtimes.payload(runtime)

    assert payload.id == "rt-payload"
    assert payload.workspace_id == "ws-runtime"
    assert payload.host == "host-z"
    assert payload.os == "linux"
    assert payload.repo == "onebackend-v3"
    assert payload.branch == "main"
    assert payload.worktree_path == "/tmp/ws-runtime/payload"
    assert payload.runner_id == "runner-7"
    assert payload.session_id == "sess-7"
    assert payload.tmux_session_id == "devide_payload"
    assert payload.isolation_mode == "worktree"
    assert payload.status == "provisioned"
    assert payload.capabilities == ["git"]
    assert payload.tools == ["mix"]
    assert payload.concurrency_limit == 2
    assert payload.active_assignments == 1
    assert payload.created_at == DateTime.to_iso8601(created)
    assert payload.heartbeat_at == DateTime.to_iso8601(created)
    # Unset timestamps iso to nil.
    assert payload.expired_at == nil
    assert payload.cleaned_at == nil
    assert payload.failure_reason == nil
    # No runtime_profile -> nil; no preview server -> nil; no surfaces.
    assert payload.runtime_profile == nil
    assert payload.preview_server == nil
    assert payload.preview_surfaces == []
    assert payload.metadata == %{}
  end

  test "runtime_profile and runtime_preview_server return nil when absent" do
    {:ok, runtime} =
      RuntimeSeed.seed_runtime("ws-runtime", runtime_id: "rt-bare", status: "provisioned")

    assert Runtimes.runtime_profile(runtime) == nil
    assert Runtimes.runtime_preview_server(runtime) == nil
    assert Runtimes.runtime_preview_surfaces(runtime) == []
  end

  # ---- event_payload / project_lifecycle ----

  test "event_payload maps lifecycle event fields and iso timestamp" do
    inserted = ~U[2026-06-02 08:00:00Z]

    event = %LifecycleEvent{
      id: "ev-1",
      runtime_id: "rt-1",
      workspace_id: "ws-runtime",
      event: "runtime_requested",
      from_status: nil,
      to_status: "requested",
      actor_id: "actor-1",
      assignment_id: "assign-1",
      runner_id: "runner-1",
      metadata: %{"k" => "v"},
      inserted_at: inserted
    }

    payload = Runtimes.event_payload(event)

    assert payload.id == "ev-1"
    assert payload.runtime_id == "rt-1"
    assert payload.workspace_id == "ws-runtime"
    assert payload.event == "runtime_requested"
    assert payload.from_status == nil
    assert payload.to_status == "requested"
    assert payload.actor_id == "actor-1"
    assert payload.assignment_id == "assign-1"
    assert payload.runner_id == "runner-1"
    assert payload.metadata == %{"k" => "v"}
    assert payload.inserted_at == DateTime.to_iso8601(inserted)
  end

  test "event_payload defaults nil metadata to an empty map" do
    event = %LifecycleEvent{
      id: "ev-2",
      runtime_id: "rt-2",
      workspace_id: "ws-runtime",
      event: "runtime_heartbeat",
      to_status: "provisioned",
      metadata: nil,
      inserted_at: nil
    }

    payload = Runtimes.event_payload(event)
    assert payload.metadata == %{}
    assert payload.inserted_at == nil
  end

  test "project_lifecycle reduces a valid event stream to the final status" do
    events = [
      lifecycle_event("runtime_requested"),
      lifecycle_event("runtime_provisioned"),
      lifecycle_event("runtime_heartbeat"),
      lifecycle_event("runtime_expired")
    ]

    assert {:ok, "expired"} = Runtimes.project_lifecycle(events)
  end

  test "project_lifecycle halts with an error on an unknown event" do
    events = [lifecycle_event("runtime_requested"), lifecycle_event("bogus_event")]
    assert {:error, :unknown_runtime_event} = Runtimes.project_lifecycle(events)
  end

  # ---- normalize_filter arms via list_runtimes ----

  test "list_runtimes with no filters returns all runtimes ordered by creation" do
    earlier = ~U[2026-06-01 00:00:00Z]
    later = ~U[2026-06-02 00:00:00Z]

    {:ok, _b} =
      RuntimeSeed.seed_runtime("ws-runtime", runtime_id: "rt-later", created_at: later)

    {:ok, _a} =
      RuntimeSeed.seed_runtime("ws-runtime", runtime_id: "rt-earlier", created_at: earlier)

    ids = Runtimes.list_runtimes() |> Enum.map(& &1.id)
    assert ids == ["rt-earlier", "rt-later"]
  end

  test "list_runtimes drops nil/empty/empty-list filter values (normalize_filter reject arm)" do
    {:ok, _r} =
      RuntimeSeed.seed_runtime("ws-runtime", runtime_id: "rt-norm", status: "provisioned")

    # workspace_id is real; the rest are empty and must be dropped, not matched.
    result =
      Runtimes.list_runtimes(%{
        "workspace_id" => "ws-runtime",
        "status" => nil,
        "branch" => "",
        "tools" => []
      })

    assert Enum.map(result, & &1.id) == ["rt-norm"]
  end

  test "list_runtimes stringifies atom filter keys (normalize_filter map arm)" do
    {:ok, _r} =
      RuntimeSeed.seed_runtime("ws-runtime", runtime_id: "rt-atomkey", status: "provisioned")

    result = Runtimes.list_runtimes(%{workspace_id: "ws-runtime", status: "provisioned"})
    assert Enum.map(result, & &1.id) == ["rt-atomkey"]
  end

  test "list_runtimes with a non-map filter normalizes to an empty filter" do
    {:ok, _r} = RuntimeSeed.seed_runtime("ws-runtime", runtime_id: "rt-nonmap")
    # normalize_filter(_) -> %{} : returns everything.
    assert ["rt-nonmap"] = Runtimes.list_runtimes(:not_a_map) |> Enum.map(& &1.id)
  end

  test "list_runtimes filters by status and id" do
    {:ok, _p} =
      RuntimeSeed.seed_runtime("ws-runtime", runtime_id: "rt-p", status: "provisioned")

    {:ok, _e} = RuntimeSeed.seed_runtime("ws-runtime", runtime_id: "rt-e", status: "expired")

    assert ["rt-p"] = Runtimes.list_runtimes(%{"status" => "provisioned"}) |> Enum.map(& &1.id)
    assert ["rt-e"] = Runtimes.list_runtimes(%{"id" => "rt-e"}) |> Enum.map(& &1.id)
  end

  defp lifecycle_event(name) do
    %LifecycleEvent{
      id: Ecto.UUID.generate(),
      runtime_id: "rt-x",
      workspace_id: "ws-runtime",
      event: name,
      to_status: nil,
      metadata: %{},
      inserted_at: DateTime.utc_now()
    }
  end

  defp seed_workspace(id, path \\ nil) do
    {:ok, _} =
      State.sync(%Workspace{
        id: id,
        name: "runtime",
        user: "alice",
        branch: "main",
        status: :running,
        path: path || "/tmp/#{id}",
        metadata: %{"id" => id, "repo" => "onebackend-v3", "branch" => "main"}
      })

    {:ok, _} =
      State.persist_isolation(id, %DbIsolation{
        isolation: :local,
        source: :env_file,
        summary: "local",
        detected_at: DateTime.utc_now()
      })
  end

  defp restore_env(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore_env(key, value), do: Application.put_env(:dev_ide, key, value)
end
