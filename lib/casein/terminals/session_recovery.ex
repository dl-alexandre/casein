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

  # Flap cap. A session whose tmux cwd is gone (deleted worktree) is recreated
  # by the owner's drift check, dies again immediately, and is "recreated"
  # again on the next tick — forever, once every @tmux_drift_check_interval_ms.
  # Each notice re-banners viewers and re-drives template recovery, so cap how
  # many notices one {workspace, sid} may emit per window. The counter resets
  # once a full window passes without a notice, so a genuine tmux wipe an hour
  # later still notifies.
  @flap_window_ms 300_000
  @max_notices_per_window 3

  defp dedupe_ms, do: Application.get_env(:casein, :session_recovery_dedupe_ms, @dedupe_ms)

  defp flap_window_ms,
    do: Application.get_env(:casein, :session_recovery_flap_window_ms, @flap_window_ms)

  defp max_notices_per_window,
    do: Application.get_env(:casein, :session_recovery_max_notices, @max_notices_per_window)

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
  drift + term_exit recover cannot double-flash or double-apply templates, and
  caps a flapping session at #{@max_notices_per_window} notices per
  #{@flap_window_ms}ms window (returns `:flapping` once capped).
  """
  @spec notify_session_recreated(keyword()) :: notice() | :deduped | :flapping
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

    case admit(workspace_id, sid) do
      :ok ->
        emit_notice(notice)
        notice

      :deduped ->
        Logger.debug(
          "tmux session recreated notify deduped session=#{tmux_session} reason=#{inspect(reason)}"
        )

        :deduped

      {:flapping, :first} ->
        Logger.warning(
          "tmux session keeps being recreated; suppressing recovery notices " <>
            "session=#{tmux_session} reason=#{inspect(reason)} " <>
            "max=#{max_notices_per_window()} window_ms=#{flap_window_ms()}"
        )

        :telemetry.execute(
          [:casein, :terminals, :session, :recreate_flap],
          %{count: 1},
          %{reason: reason}
        )

        :flapping

      {:flapping, :again} ->
        :flapping
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

  # Decide whether this notify may be emitted, recording it when it may.
  # Fails open (`:ok`) for unkeyed notifies and for any ETS trouble — losing a
  # recovery banner is worse than emitting a duplicate one.
  defp admit(workspace_id, sid)
       when is_binary(workspace_id) and is_binary(sid) do
    ensure_table!()
    key = {workspace_id, sid}
    now = System.monotonic_time(:millisecond)

    case window_for(key, now) do
      :deduped ->
        :deduped

      {count, window_started_at} ->
        count = count + 1
        max = max_notices_per_window()
        true = :ets.insert(@dedupe_table, {key, now, count, window_started_at})

        cond do
          count <= max -> :ok
          count == max + 1 -> {:flapping, :first}
          true -> {:flapping, :again}
        end
    end
  rescue
    _ -> :ok
  end

  defp admit(_, _), do: :ok

  # `:deduped` while the previous notice is still inside the collapse window,
  # otherwise `{notices_so_far, window_start}` — with the counter restarted once
  # a full flap window has elapsed since it opened.
  defp window_for(key, now) do
    case :ets.lookup(@dedupe_table, key) do
      [{^key, last_at, count, window_started_at}]
      when is_integer(last_at) and is_integer(count) and is_integer(window_started_at) ->
        cond do
          now - last_at < dedupe_ms() -> :deduped
          now - window_started_at >= flap_window_ms() -> {0, now}
          true -> {count, window_started_at}
        end

      _ ->
        {0, now}
    end
  end

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
