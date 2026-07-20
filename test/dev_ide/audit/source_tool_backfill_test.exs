defmodule DevIDE.Audit.SourceToolBackfillTest do
  @moduledoc """
  Verifies the `source`/`tool` columns added to `audit_events` and the
  migration's action-prefix backfill.

  The test schema is already migrated, so legacy rows are simulated by
  inserting action-prefixed rows with NULL source/tool and replaying the
  literal backfill statements exposed by the migration module.
  """
  use DevIDE.DataCase, async: false

  alias DevIDE.Audit
  alias DevIDE.Audit.EctoAdapter
  alias DevIDE.Repo

  @migration_path "priv/repo/migrations/20260716080000_add_source_tool_to_audit_events.exs"

  setup do
    prev = Application.get_env(:dev_ide, :audit_adapter)
    Application.put_env(:dev_ide, :audit_adapter, EctoAdapter)
    on_exit(fn -> Application.put_env(:dev_ide, :audit_adapter, prev) end)
    :ok
  end

  defp migration_module do
    case Code.ensure_loaded(DevIDE.Repo.Migrations.AddSourceToolToAuditEvents) do
      {:module, mod} ->
        mod

      _ ->
        [{mod, _} | _] = Code.require_file(@migration_path)
        mod
    end
  end

  defp insert_legacy_row(action, workspace_id) do
    {:ok, id} = Ecto.UUID.generate() |> Ecto.UUID.dump()

    Repo.insert_all("audit_events", [
      %{
        id: id,
        workspace_id: workspace_id,
        actor_id: "mcp",
        action: action,
        metadata: %{},
        inserted_at: DateTime.utc_now()
      }
    ])

    :ok
  end

  defp run_backfill do
    for sql <- migration_module().backfill_sql(), do: Repo.query!(sql)
    :ok
  end

  test "backfill parses source and tool from legacy MCP action strings" do
    insert_legacy_row("agent.terminal_terminal_send_command", "ws-bf")
    insert_legacy_row("agent.terminal_annotation_propose", "ws-bf")
    insert_legacy_row("agent.preview_preview_click", "ws-bf")
    insert_legacy_row("agent.artifact_artifact_create", "ws-bf")
    # Non-MCP actions must be left untouched.
    insert_legacy_row("run.started", "ws-bf")
    insert_legacy_row("agent.blocked", "ws-bf")

    run_backfill()

    by_action =
      "ws-bf"
      |> Audit.recent_for(10)
      |> Map.new(&{&1.action, &1})

    assert %{source: "terminal_mcp", tool: "terminal_send_command"} =
             by_action["agent.terminal_terminal_send_command"]

    assert %{source: "terminal_mcp", tool: "annotation_propose"} =
             by_action["agent.terminal_annotation_propose"]

    assert %{source: "preview_mcp", tool: "preview_click"} =
             by_action["agent.preview_preview_click"]

    assert %{source: "artifact_mcp", tool: "artifact_create"} =
             by_action["agent.artifact_artifact_create"]

    assert %{source: nil, tool: nil} = by_action["run.started"]
    assert %{source: nil, tool: nil} = by_action["agent.blocked"]
  end

  test "backfill SQL has the same semantics on SQLite desktop releases" do
    {:ok, conn} = Exqlite.Sqlite3.open(":memory:")

    try do
      :ok =
        Exqlite.Sqlite3.execute(
          conn,
          "CREATE TABLE audit_events (action TEXT, source TEXT, tool TEXT)"
        )

      :ok =
        Exqlite.Sqlite3.execute(
          conn,
          "INSERT INTO audit_events (action) VALUES ('agent.terminal_terminal_send_command')"
        )

      for sql <- migration_module().backfill_sql(), do: :ok = Exqlite.Sqlite3.execute(conn, sql)
      {:ok, statement} = Exqlite.Sqlite3.prepare(conn, "SELECT source, tool FROM audit_events")

      assert {:row, ["terminal_mcp", "terminal_send_command"]} =
               Exqlite.Sqlite3.step(conn, statement)

      :ok = Exqlite.Sqlite3.release(conn, statement)
    after
      :ok = Exqlite.Sqlite3.close(conn)
    end
  end

  test "backfill does not overwrite rows that already carry a source" do
    {:ok, _} =
      Audit.emit(%{
        action: "agent.terminal_terminal_send_keys",
        workspace_id: "ws-bf2",
        source: "terminal_mcp",
        tool: "custom_tool_value"
      })

    run_backfill()

    [event] = Audit.recent_for("ws-bf2", 1)
    assert event.tool == "custom_tool_value"
  end

  test "recent_for_tool reads backfilled rows through the indexed column" do
    insert_legacy_row("agent.terminal_terminal_send_command", "ws-bf3")
    insert_legacy_row("agent.terminal_terminal_send_keys", "ws-bf3")
    insert_legacy_row("agent.terminal_terminal_send_command", "ws-other")

    run_backfill()

    events = Audit.recent_for_tool("ws-bf3", "terminal_send_command", 10)
    assert length(events) == 1
    assert hd(events).action == "agent.terminal_terminal_send_command"
  end

  test "source and tool round-trip through emit and recent_for_tool" do
    {:ok, _} =
      Audit.emit(%{
        action: "agent.terminal_terminal_send_command",
        workspace_id: "ws-rt",
        source: "terminal_mcp",
        tool: "terminal_send_command"
      })

    [event] = Audit.recent_for_tool("ws-rt", "terminal_send_command", 5)
    assert event.source == "terminal_mcp"
    assert event.tool == "terminal_send_command"
  end
end
