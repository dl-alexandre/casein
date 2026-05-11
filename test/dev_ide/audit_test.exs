defmodule DevIDE.AuditTest do
  use ExUnit.Case, async: false
  alias DevIDE.Audit
  alias DevIDE.Audit.Event

  setup do
    Audit.clear()
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
end
