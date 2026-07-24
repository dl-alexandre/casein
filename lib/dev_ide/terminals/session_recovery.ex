defmodule Casein.Terminals.SessionRecovery do
  @moduledoc """
  Cross-cutting recovery helpers when a tmux session (or whole server) is gone.

  Prefer calling from `SessionOwner` (has manager `workspace_id` UUID) after a
  backend recover that recreated a missing session. Session still reseeds from
  the archive but does not notify — wrong keys and double-flashes are avoided.
  """

  require Logger

  alias Casein.Audit
  alias Casein.Terminals.{ScrollbackArchive, SessionEvents, TemplatePreference}

  @pubsub Casein.PubSub
  @dedupe_table :casein_session_recovery_dedupe
  # Collapse double notifies from drift + term_exit recover within this window.
  @dedupe_ms 5_000

  @doc "Ensure the dedupe ETS table exists (idempotent)."
  def ensure_table! do
    case :ets.whereis(@dedupe_table) do
      :undefined ->
        access = Application.get_env(:casein, :ets_table_access, :protected)
        :ets.new(@dedupe_table, [:named_table, access, :set])
        :ok

      _ ->
        :ok
    end
  end

  @doc "PubSub topic for workspace-wide recovery notices (LiveView banners)."
  def workspace_topic(workspace_id) when is_binary(workspace_id),
    do: "terminal_recovery:#{workspace_id}"

  @doc "Subscribe the LiveView (or any process) to recovery notices."
  def subscribe_workspace(workspace_id) when is_binary(workspace_id) do
    Phoenix.PubSub.subscribe(@pubsub, workspace_topic(workspace_id))
  end

  def subscribe_workspace(_), do: :error

  @type notice :: %{
          type: :session_recreated,
          workspace_id: String.t() | nil,
          sid: String.t() | nil,
          tmux_session: String.t(),
          reason: atom() | String.t() | nil,
          history_restored?: boolean(),
          template_id: String.t() | nil
        }

  @doc """
  Record that `tmux_session` was recreated empty after the previous server/session vanished.

  `workspace_id` **must** be the manager UUID that LiveView uses for
  `subscribe_workspace/1` — not the tmux workspace name key.

  Dedupes identical `{workspace_id, sid}` notifies within #{@dedupe_ms}ms so
  drift + term_exit recover cannot double-flash or double-apply templates.
  """
  @spec notify_session_recreated(keyword()) :: notice() | :deduped
  def notify_session_recreated(opts) when is_list(opts) do
    tmux_session = Keyword.fetch!(opts, :tmux_session)
    workspace_id = Keyword.get(opts, :workspace_id)
    sid = Keyword.get(opts, :sid)
    reason = Keyword.get(opts, :reason, :tmux_server_or_session_missing)
    history_restored? = Keyword.get(opts, :history_restored?, false)

    template_id =
      Keyword.get_lazy(opts, :template_id, fn ->
        recovery_template(workspace_id)
      end)

    notice = %{
      type: :session_recreated,
      workspace_id: workspace_id,
      sid: sid,
      tmux_session: tmux_session,
      reason: reason,
      history_restored?: history_restored?,
      template_id: template_id
    }

    if deduped?(workspace_id, sid) do
      Logger.debug(
        "tmux session recreated notify deduped session=#{tmux_session} reason=#{inspect(reason)}"
      )

      :deduped
    else
      mark_notified(workspace_id, sid)
      emit_notice(notice)
      notice
    end
  end

  defp emit_notice(
         %{
           tmux_session: tmux_session,
           workspace_id: workspace_id,
           sid: sid,
           reason: reason,
           history_restored?: history_restored?,
           template_id: template_id
         } = notice
       ) do
    Logger.warning(
      "tmux session recreated empty session=#{tmux_session} reason=#{inspect(reason)} history_restored=#{history_restored?}"
    )

    :telemetry.execute(
      [:casein, :terminals, :session, :recreated],
      %{count: 1},
      %{
        reason: reason,
        history_restored: history_restored?,
        has_template: is_binary(template_id)
      }
    )

    if is_binary(workspace_id) do
      _ =
        Audit.emit!(%{
          action: "terminal.session_recreated",
          workspace_id: workspace_id,
          actor_id: "tmux_recovery",
          target_type: "tmux_session",
          target_ref: tmux_session,
          metadata: %{
            "tmux_session" => tmux_session,
            "sid" => sid,
            "reason" => to_string(reason),
            "history_restored" => history_restored?,
            "template_id" => template_id
          }
        })

      Phoenix.PubSub.broadcast(
        @pubsub,
        workspace_topic(workspace_id),
        {:terminal_recovery, notice}
      )
    end

    if is_binary(workspace_id) and is_binary(sid) do
      SessionEvents.broadcast_recovery(workspace_id, sid, notice)
    end

    :ok
  end

  defp deduped?(workspace_id, sid)
       when is_binary(workspace_id) and is_binary(sid) do
    ensure_table!()
    key = {workspace_id, sid}
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@dedupe_table, key) do
      [{^key, at}] when is_integer(at) and now - at < @dedupe_ms -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp deduped?(_, _), do: false

  defp mark_notified(workspace_id, sid)
       when is_binary(workspace_id) and is_binary(sid) do
    ensure_table!()
    true = :ets.insert(@dedupe_table, {{workspace_id, sid}, System.monotonic_time(:millisecond)})
    :ok
  rescue
    _ -> :ok
  end

  defp mark_notified(_, _), do: :ok

  @doc """
  Seed bytes for a brand-new session from the archive (if any).

  Returns `{buffer, history_restored?}`.
  """
  @spec seed_from_archive(String.t()) :: {binary(), boolean()}
  def seed_from_archive(tmux_session) when is_binary(tmux_session) do
    data = ScrollbackArchive.get(tmux_session)

    if data == <<>> do
      {<<>>, false}
    else
      banner =
        "\r\n\e[33m[Casein]\e[0m tmux session was recreated; restoring archived scrollback tail.\r\n\r\n"

      {banner <> data, true}
    end
  end

  def seed_from_archive(_), do: {<<>>, false}

  @doc """
  Template to auto-apply after empty recreate for this workspace.

  Returns a stored preference when present; otherwise `"agent_pair"` so agent
  workspaces regain layout without a prior explicit apply.
  """
  @spec recovery_template(String.t() | nil) :: String.t() | nil
  def recovery_template(workspace_id) when is_binary(workspace_id) do
    TemplatePreference.get(workspace_id) || TemplatePreference.default_recovery_template()
  end

  def recovery_template(_), do: TemplatePreference.default_recovery_template()
end
