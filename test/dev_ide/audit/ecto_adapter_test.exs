defmodule DevIDE.Audit.EctoAdapterTest do
  use DevIde.DataCase, async: false

  alias DevIDE.Audit
  alias DevIDE.Audit.{Event, EctoAdapter}

  setup do
    prev = Application.get_env(:dev_ide, :audit_adapter)
    Application.put_env(:dev_ide, :audit_adapter, EctoAdapter)
    on_exit(fn -> Application.put_env(:dev_ide, :audit_adapter, prev) end)
    :ok
  end

  test "emit returns {:ok, event} and persists across queries" do
    {:ok, %Event{id: id, action: "file.saved"} = e} =
      Audit.emit(%{
        action: "file.saved",
        workspace_id: "w1",
        target_ref: "lib/a.ex",
        decision: :allow,
        metadata: %{"source" => "ui"}
      })

    [stored] = Audit.recent_for("w1", 5)
    assert stored.id == id
    assert stored.action == "file.saved"
    assert stored.decision == :allow
    assert stored.metadata["source"] == "ui"
    assert %DateTime{} = e.inserted_at
  end

  test "recent_for filters by workspace and orders newest first" do
    {:ok, _} = Audit.emit(%{action: "command.started", workspace_id: "a"})
    Process.sleep(2)
    {:ok, _} = Audit.emit(%{action: "command.finished", workspace_id: "a"})
    {:ok, _} = Audit.emit(%{action: "command.started", workspace_id: "b"})

    actions_a = Audit.recent_for("a", 10) |> Enum.map(& &1.action)
    assert actions_a == ["command.finished", "command.started"]
    assert Audit.recent_for("a", 1) |> length() == 1
    assert Audit.recent_for("b", 10) |> Enum.map(& &1.action) == ["command.started"]
  end

  test "recent_with_action_prefix returns only matching-prefix rows, newest first" do
    {:ok, _} = Audit.emit(%{action: "run.started", workspace_id: "wp", target_ref: "r1"})
    Process.sleep(2)
    {:ok, _} = Audit.emit(%{action: "file.saved", workspace_id: "wp", target_ref: "f1"})
    Process.sleep(2)
    {:ok, _} = Audit.emit(%{action: "run.succeeded", workspace_id: "wp", target_ref: "r1"})
    # Same prefix, different workspace — must be excluded.
    {:ok, _} = Audit.emit(%{action: "run.started", workspace_id: "other", target_ref: "r9"})

    actions = Audit.recent_with_action_prefix("wp", "run.", 10) |> Enum.map(& &1.action)
    assert actions == ["run.succeeded", "run.started"]
    assert Audit.recent_with_action_prefix("wp", "run.", 1) |> length() == 1
  end

  test "recent_with_action_prefix treats LIKE metacharacters in the prefix literally" do
    {:ok, _} = Audit.emit(%{action: "run.started", workspace_id: "wl"})
    {:ok, _} = Audit.emit(%{action: "rXn.started", workspace_id: "wl"})

    # "ru_." must not match "rXn." — the underscore is escaped, not a wildcard.
    actions = Audit.recent_with_action_prefix("wl", "ru_.", 10) |> Enum.map(& &1.action)
    assert actions == []
  end

  test "list caps results" do
    for i <- 1..5 do
      {:ok, _} = Audit.emit(%{action: "x", workspace_id: "ws", target_ref: "#{i}"})
    end

    assert Audit.list(limit: 3) |> length() == 3
  end

  test "metadata round-trips, including atom mode tag from emit_decision" do
    decision = DevIDE.Policy.can_apply_proposal?(%{workspace_id: "wm"})
    Audit.emit_decision(decision, %{workspace_id: "wm", target_ref: "fix.diff"})

    [stored] = Audit.recent_for("wm", 1)
    assert stored.action == "policy.blocked"
    assert stored.decision == :deny
    assert stored.reason == :forbidden
    # mode atom is JSON-serialized as a string
    assert stored.metadata["mode"] in ["manual", :manual |> Atom.to_string()]
  end

  test "oversized metadata is replaced with a truncated marker" do
    huge = String.duplicate("x", 64 * 1024)
    {:ok, _} = Audit.emit(%{action: "big", workspace_id: "wt", metadata: %{"blob" => huge}})
    [stored] = Audit.recent_for("wt", 1)
    assert stored.metadata == %{"truncated" => true}
  end

  test "non-map metadata is normalized to %{}" do
    {:ok, _} = Audit.emit(%{action: "weird", workspace_id: "wn", metadata: nil})
    [stored] = Audit.recent_for("wn", 1)
    assert stored.metadata == %{}
  end

  test "unknown decision/reason atoms in stored rows decode safely" do
    # Insert directly to simulate a string the runtime hasn't seen as an atom.
    {:ok, _} = Audit.emit(%{action: "x", workspace_id: "wq", decision: :allow, reason: nil})
    [stored] = Audit.recent_for("wq", 1)
    assert stored.decision == :allow
    assert stored.reason == nil
  end

  test "list_by_correlation returns only the chain, ascending" do
    cid =
      DevIDE.Signals.Context.with_new(fn ->
        {:ok, _} = Audit.emit(%{action: "chain.first", workspace_id: "wcor"})
        Process.sleep(2)
        {:ok, _} = Audit.emit(%{action: "chain.second", workspace_id: "wcor"})
        DevIDE.Signals.Context.current().trace_id
      end)

    {:ok, _} = Audit.emit(%{action: "unrelated", workspace_id: "wcor"})

    chain = Audit.list_by_correlation(cid)
    assert Enum.map(chain, & &1.action) == ["chain.first", "chain.second"]
    assert Enum.all?(chain, &(&1.metadata["correlation_id"] == cid))
  end

  test "metadata truncation preserves the causality keys" do
    huge = String.duplicate("x", 64 * 1024)

    cid =
      DevIDE.Signals.Context.with_new(fn ->
        {:ok, _} = Audit.emit(%{action: "big", workspace_id: "wtc", metadata: %{"blob" => huge}})
        DevIDE.Signals.Context.current().trace_id
      end)

    [stored] = Audit.recent_for("wtc", 1)
    assert stored.metadata["truncated"] == true
    assert stored.metadata["correlation_id"] == cid
    refute Map.has_key?(stored.metadata, "blob")
    assert [%{action: "big"}] = Audit.list_by_correlation(cid)
  end
end
