defmodule DevIDE.AuditTest do
  use ExUnit.Case, async: false
  alias DevIDE.Audit
  alias DevIDE.Audit.Event
  alias DevIDE.Audit.MemoryAdapter
  alias DevIDE.Policy.Decision

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

  defp restore_env(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore_env(key, value), do: Application.put_env(:dev_ide, key, value)
end
