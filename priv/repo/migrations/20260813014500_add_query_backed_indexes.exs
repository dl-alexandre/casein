defmodule Casein.Repo.Migrations.AddQueryBackedIndexes do
  use Ecto.Migration

  # Each index below is justified by a named query that uses it as a leading
  # key. An unused index is pure write cost (#921: writes are already 92% of
  # the prod DB). Do not add indexes on runtime_lifecycle_events here — #921
  # is about to guard that table's write volume.
  #
  # Intentionally not added:
  # - annotations(pane_id, inserted_at desc) — list_for_workspace/2 always
  #   leads with workspace_id, and pane_id is a recycling tmux id ("%3"),
  #   not a globally selective key.
  # - workspace_runtimes(branch) — no caller filters by branch alone
  #   (existing (repo, branch) already covers the repo+branch path).
  def change do
    # Casein.Mobile.TerminalSessions.lease_owned_sid?/2
    #   WHERE workspace_id = ? AND sid = ? AND state != 'deleted'
    # Existing indexes put workspace_id second (device_link_id, workspace_id),
    # so this lease-authorization path sequential-scanned lease history.
    create index(:mobile_terminal_sessions, [:workspace_id, :sid])

    # Casein.Runtimes.cleanup_expired/2 and Casein.Runtimes.Reaper
    #   list_runtimes(%{"status" => "expired"})
    # Existing indexes trail status: (workspace_id, status), (host_id, status).
    create index(:workspace_runtimes, [:status])

    # Casein.Previews.Control
    #   latest_observation_for_preview/1, close_sessions_for_preview/1,
    #   open_sessions_for_preview/1
    #   WHERE preview_id = ? AND status = 'open'
    # Only (preview_id) existed; the composite matches the equality pair.
    create index(:preview_control_sessions, [:preview_id, :status])

    # Casein.Notifications.unread_count/1 and mark_all_read/2
    #   WHERE user_id = ? AND read_at IS NULL AND resolved_at IS NULL
    create index(:notifications, [:user_id],
             where: "read_at IS NULL AND resolved_at IS NULL",
             name: :notifications_user_unread_index
           )
  end
end
