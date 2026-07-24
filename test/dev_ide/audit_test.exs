defmodule Casein.AuditTest do
  use Casein.TestCase, async: false
  alias Casein.Audit
  alias Casein.Audit.Event
  alias Casein.Audit.MemoryAdapter
  alias Casein.Policy.Decision

  setup do
    prev_adapter = Application.get_env(:dev_ide, :audit_adapter)
    Application.put_env(:dev_ide, :audit_adapter, MemoryAdapter)
    MemoryAdapter.clear()

    on_exit(fn ->
      MemoryAdapter.clear()
      restore_env(:audit_adapter, prev_adapter)
    end)

    :ok
  end

  test "emit returns {:ok, event} with required fields" do
    {:ok, e} = Audit.emit(%{action: "file.saved", workspace_id: "w1", target_ref: "lib/a.ex"})
    assert %Event{action: "file.saved", workspace_id: "w1", target_ref: "lib/a.ex"} = e
    assert is_binary(e.id) and byte_size(e.id) > 0
    assert %DateTime{} = e.inserted_at
  end

  test "recent_for filters by workspace and applies limit" do
    Audit.emit(%{action: "command.started", workspace_id: "a"})
    Audit.emit(%{action: "command.started", workspace_id: "b"})
    Audit.emit(%{action: "command.finished", workspace_id: "a"})

    a_events = Audit.recent_for("a", 10)
    assert Enum.map(a_events, & &1.action) == ["command.finished", "command.started"]
    assert Audit.recent_for("a", 1) |> length() == 1
  end

  test "list returns most recent first" do
    Audit.emit(%{action: "first"})
    Audit.emit(%{action: "second"})
    [latest, prior | _] = Audit.list()
    assert latest.action == "second"
    assert prior.action == "first"
  end

  test "list applies limit and clear removes memory events" do
    Audit.emit(%{action: "first"})
    Audit.emit(%{action: "second"})
    Audit.emit(%{action: "third"})

    assert Audit.list(limit: 2) |> Enum.map(& &1.action) == ["third", "second"]

    assert :ok = Audit.clear()
    assert Audit.list() == []
  end

  defmodule RaisingAdapter do
    # Simulates the Ecto adapter during a Postgres outage: Repo.insert raises
    # (DBConnection.ConnectionError) instead of returning {:error, _}.
    def record(_event), do: raise("connection not available")
  end

  test "emit! absorbs adapter exceptions — GenServer hot paths must not crash" do
    Application.put_env(:dev_ide, :audit_adapter, RaisingAdapter)

    assert Audit.emit!(%{action: "ops.pg_saturation_raised", workspace_id: "_ops"}) == nil
  end

  test "recent_for_tool rejects a nil workspace instead of diverging by adapter" do
    # apply/3 keeps the deliberate contract violation away from compile-time
    # type checking — the point is the runtime guard.
    assert_raise FunctionClauseError, fn ->
      apply(Audit, :recent_for_tool, [nil, "terminal_send_command"])
    end
  end

  test "emit_decision records policy denials and merges mode metadata" do
    decision = Decision.deny(:apply_proposal, :review, :not_implemented)

    Audit.emit_decision(decision, %{
      workspace_id: "ws-policy",
      target_ref: "fix.diff",
      metadata: %{source: "live"}
    })

    [event] = Audit.recent_for("ws-policy", 1)
    assert event.action == "policy.blocked"
    assert event.decision == :deny
    assert event.reason == :not_implemented
    assert event.metadata == %{source: "live", mode: :review}
  end

  describe "causality" do
    alias Casein.Signals.Context

    test "emit inside a context stamps correlation and chains causation" do
      {cid, first, second} =
        Context.with_new(fn ->
          cid = Context.current().trace_id
          {:ok, first} = Audit.emit(%{action: "chain.first", workspace_id: "wc"})
          {:ok, second} = Audit.emit(%{action: "chain.second", workspace_id: "wc"})
          {cid, first, second}
        end)

      assert first.metadata["correlation_id"] == cid
      refute Map.has_key?(first.metadata, "causation_id")
      assert second.metadata["correlation_id"] == cid
      assert second.metadata["causation_id"] == first.id
    end

    test "emit outside a context leaves metadata untouched" do
      {:ok, e} = Audit.emit(%{action: "plain", workspace_id: "wp", metadata: %{"a" => 1}})
      assert e.metadata == %{"a" => 1}
    end

    test "list_by_correlation returns the chain in causal order" do
      cid =
        Context.with_new(fn ->
          {:ok, _} = Audit.emit(%{action: "chain.first", workspace_id: "wc"})
          {:ok, _} = Audit.emit(%{action: "chain.second", workspace_id: "wc"})
          Context.current().trace_id
        end)

      {:ok, _} = Audit.emit(%{action: "unrelated", workspace_id: "wc"})

      assert Audit.list_by_correlation(cid) |> Enum.map(& &1.action) ==
               ["chain.first", "chain.second"]
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore_env(key, value), do: Application.put_env(:dev_ide, key, value)
end
