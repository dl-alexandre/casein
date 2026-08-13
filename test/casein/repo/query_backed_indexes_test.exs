defmodule Casein.Repo.QueryBackedIndexesTest do
  use Casein.DataCase, async: true

  # #926: every added index must be the leading key of a named query.
  # An unused index is pure write cost (#921: writes are already 92% of the
  # prod DB). This test fails if a required index is dropped, if a rejected
  # unused index is added, or if runtime_lifecycle_events is re-indexed
  # without coordinating with #921.

  @required [
    %{
      table: "mobile_terminal_sessions",
      columns: ["workspace_id", "sid"],
      serves: "Casein.Mobile.TerminalSessions.lease_owned_sid?/2"
    },
    %{
      table: "workspace_runtimes",
      columns: ["status"],
      serves: "Casein.Runtimes.list_runtimes(%{\"status\" => \"expired\"})"
    },
    %{
      table: "preview_control_sessions",
      columns: ["preview_id", "status"],
      serves: "Casein.Previews.Control open-session queries"
    }
  ]

  test "required query-backed indexes exist" do
    for spec <- @required do
      assert index_covering?(spec.table, spec.columns),
             "missing index on #{spec.table}(#{Enum.join(spec.columns, ", ")}) serving #{spec.serves}"
    end

    assert Enum.any?(indexes("notifications"), fn %{def: definition} ->
             String.contains?(definition, "(user_id)") and
               String.contains?(definition, "read_at IS NULL") and
               String.contains?(definition, "resolved_at IS NULL")
           end),
           "missing notifications_user_unread_index serving Notifications.unread_count/1"
  end

  test "lease_owned_sid?/2 uses (workspace_id, sid)" do
    assert explain_uses?(
             """
             SELECT 1 FROM mobile_terminal_sessions
             WHERE workspace_id = $1 AND sid = $2 AND state <> 'deleted'
             """,
             ["ws", "mob-x"],
             "mobile_terminal_sessions_workspace_id_sid_index"
           )
  end

  test "status-only runtime list uses workspace_runtimes(status)" do
    assert explain_uses?(
             "SELECT id FROM workspace_runtimes WHERE status = $1",
             ["expired"],
             "workspace_runtimes_status_index"
           )
  end

  test "open preview sessions use (preview_id, status)" do
    assert explain_uses?(
             """
             SELECT id FROM preview_control_sessions
             WHERE preview_id = $1 AND status = $2
             """,
             [1, "open"],
             "preview_control_sessions_preview_id_status_index"
           )
  end

  test "unread badge uses the partial user_id index" do
    assert explain_uses?(
             """
             SELECT count(*) FROM notifications
             WHERE user_id = $1 AND read_at IS NULL AND resolved_at IS NULL
             """,
             ["dev"],
             "notifications_user_unread_index"
           )
  end

  test "does not add unused or guarded indexes" do
    refute leading_key?("annotations", "pane_id"),
           "annotations(pane_id, ...) is unused: list_for_workspace/2 always " <>
             "leads with workspace_id, and pane_id recycles across workspaces"

    refute Enum.any?(indexes("workspace_runtimes"), fn %{def: definition} ->
             String.contains?(definition, "(branch)")
           end),
           "workspace_runtimes(branch) is unused: no caller filters by branch alone"

    lifecycle_names =
      "runtime_lifecycle_events"
      |> indexes()
      |> Enum.map(& &1.name)
      |> Enum.sort()

    assert lifecycle_names == [
             "runtime_lifecycle_events_event_inserted_at_desc_index",
             "runtime_lifecycle_events_pkey",
             "runtime_lifecycle_events_runtime_id_inserted_at_asc_index",
             "runtime_lifecycle_events_workspace_id_inserted_at_desc_index"
           ],
           "do not add indexes on runtime_lifecycle_events while #921 is guarding its write volume; got: " <>
             inspect(lifecycle_names)
  end

  defp indexes(table) do
    {:ok, %{rows: rows}} =
      Repo.query(
        """
        SELECT indexname, indexdef
        FROM pg_indexes
        WHERE schemaname = 'public' AND tablename = $1
        """,
        [table]
      )

    Enum.map(rows, fn [name, definition] -> %{name: name, def: definition} end)
  end

  defp index_covering?(table, columns) do
    needle = "(" <> Enum.join(columns, ", ") <> ")"

    Enum.any?(indexes(table), fn %{def: definition} ->
      String.contains?(definition, needle)
    end)
  end

  defp leading_key?(table, column) do
    Enum.any?(indexes(table), fn %{def: definition} ->
      String.contains?(definition, "(#{column})") or
        String.contains?(definition, "(#{column},")
    end)
  end

  defp explain_uses?(sql, params, index_name) do
    Repo.query!("SET LOCAL enable_seqscan = off")
    {:ok, %{rows: rows}} = Repo.query("EXPLAIN " <> sql, params)
    plan = rows |> Enum.map(&hd/1) |> Enum.join("\n")
    String.contains?(plan, index_name)
  end
end
