defmodule Casein.Deployment.DeployAuditTest do
  @moduledoc """
  Transition semantics for the durable deploy/drift audit trail: repeated
  polls with an unchanged observation must never add rows.
  """
  use Casein.TestCase, async: false

  alias Casein.Audit
  alias Casein.Audit.MemoryAdapter
  alias Casein.Deployment.DeployAudit

  @ws DeployAudit.workspace_id()

  setup do
    MemoryAdapter.clear()
    on_exit(fn -> MemoryAdapter.clear() end)
    :ok
  end

  defp record(outcome, target, extra \\ %{}) do
    Map.merge(%{"outcome" => outcome, "target_sha" => target}, extra)
  end

  defp actions do
    @ws |> Audit.recent_for(50) |> Enum.map(& &1.action)
  end

  describe "deploy pipeline transitions" do
    test "seeds silently on first observation, then emits exactly once per transition" do
      state = DeployAudit.new()

      # Boot: whatever the file says pre-dates this process — no row.
      state = DeployAudit.observe(state, record("success", "sha-old"), nil)
      assert actions() == []

      # New target goes in progress.
      state = DeployAudit.observe(state, record("in_progress", "sha-new"), nil)
      assert actions() == ["deploy.started"]

      # Repeated polls of the same attempt add nothing (phase changes included).
      state = DeployAudit.observe(state, record("in_progress", "sha-new"), nil)

      state =
        DeployAudit.observe(state, record("in_progress", "sha-new", %{"phase" => "build"}), nil)

      assert actions() == ["deploy.started"]

      # Completion emits once, repeats stay silent.
      state = DeployAudit.observe(state, record("success", "sha-new"), nil)
      state = DeployAudit.observe(state, record("success", "sha-new"), nil)
      assert actions() == ["deploy.succeeded", "deploy.started"]

      # A missing/invalid file keeps state instead of resetting it.
      state = DeployAudit.observe(state, nil, nil)
      _state = DeployAudit.observe(state, record("success", "sha-new"), nil)
      assert actions() == ["deploy.succeeded", "deploy.started"]
    end

    test "a failed attempt persists phase and reason, retry emits a fresh start" do
      state = DeployAudit.new()
      state = DeployAudit.observe(state, record("in_progress", "sha-1"), nil)
      # First in_progress observation seeded silently; drive a target change.
      state = DeployAudit.observe(state, record("in_progress", "sha-2"), nil)

      state =
        DeployAudit.observe(
          state,
          record("failed", "sha-2", %{"phase" => "gate", "reason" => "gate red: 3 failures"}),
          nil
        )

      [event | _] = Audit.recent_for(@ws, 10)
      assert event.action == "deploy.failed"
      assert event.source == "deploy"
      assert event.target_ref == "sha-2"
      assert event.metadata.phase == "gate"
      assert event.metadata.reason == "gate red: 3 failures"

      # Poller retries the same sha: a fresh in_progress is a new attempt.
      _state = DeployAudit.observe(state, record("in_progress", "sha-2"), nil)
      assert hd(actions()) == "deploy.started"
    end

    test "a retry of the same sha with the same outcome is a new attempt when started_at differs" do
      state = DeployAudit.new()
      state = DeployAudit.observe(state, record("in_progress", "sha-x"), nil)

      state =
        DeployAudit.observe(
          state,
          record("failed", "sha-x", %{"started_at" => "2026-07-16T10:00:00Z"}),
          nil
        )

      assert actions() == ["deploy.failed"]

      # The retry's in_progress window fell between two polls; its terminal
      # observation still gets its own row because started_at keys the attempt.
      _state =
        DeployAudit.observe(
          state,
          record("failed", "sha-x", %{"started_at" => "2026-07-16T10:20:00Z"}),
          nil
        )

      assert actions() == ["deploy.failed", "deploy.failed"]
    end
  end

  describe "drift transitions" do
    @drift_info %{
      reason: :revision_differs,
      current: "aaa",
      remote: "bbb",
      branch: "master",
      message: "Running revision differs from origin/master."
    }

    test "detects once, ignores repeats and unknowns, clears once" do
      state = DeployAudit.new()

      state = DeployAudit.observe(state, nil, {:drift, @drift_info})
      assert actions() == ["deploy.drift_detected"]

      [event] = Audit.recent_for(@ws, 10)
      assert event.metadata.reason == :revision_differs
      assert event.metadata.current == "aaa"
      assert event.metadata.remote == "bbb"

      # Same drift on the next polls: no new rows; lookup failures don't flap.
      state = DeployAudit.observe(state, nil, {:drift, @drift_info})
      state = DeployAudit.observe(state, nil, {:unknown, %{reason: :remote_lookup_failed}})
      assert actions() == ["deploy.drift_detected"]

      state = DeployAudit.observe(state, nil, :current)
      assert actions() == ["deploy.drift_cleared", "deploy.drift_detected"]

      _state = DeployAudit.observe(state, nil, :current)
      assert actions() == ["deploy.drift_cleared", "deploy.drift_detected"]
    end

    test "booting in the healthy state emits nothing" do
      state = DeployAudit.new()
      _state = DeployAudit.observe(state, nil, :current)
      assert actions() == []
    end

    test "nil drift status (check disabled) keeps the previous flag" do
      state = DeployAudit.new()
      state = DeployAudit.observe(state, nil, {:drift, @drift_info})
      state = DeployAudit.observe(state, nil, nil)
      _state = DeployAudit.observe(state, nil, {:drift, @drift_info})
      assert actions() == ["deploy.drift_detected"]
    end
  end
end
