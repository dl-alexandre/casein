defmodule Casein.Attention.Acknowledgement do
  @moduledoc """
  Cross-surface acknowledgement: **SEEN** and **RESOLVED**, per viewer.

  This is the single durable fact that phone cards, the notifications drawer,
  and session-rail quiet badges share. It is **not** salience (how much a signal
  matters — `Casein.Attention.Salience`) and **not** delivery (whether to page
  now — `Casein.Attention.Delivery`).

  ## SEEN vs RESOLVED

  - **SEEN** — the viewer has observed the current generation of the subject
    (watermark / `seen_at`). Clears unread dots and badges. Does **not** release
    a Needs Me pin.
  - **RESOLVED** — the viewer has dealt with the subject for this generation.
    Releases open/Needs Me from the ack side; drawer "Resolved".

  Glancing at a failed run is SEEN only. Handling the decision is RESOLVED.
  Both are required; collapsing them either pins Needs Me forever after a glance
  or clears it when the operator only scrolled past.

  ## Store

  One table: `mobile_attention_cursors` (evolved from the mobile SEEN cursor).
  There is no third read-state store. `Casein.Mobile.AttentionCursor` remains
  the Ecto schema; this module is the cross-surface API.

  ## User scope

  Every row is keyed by `user_id`. One operator settling a subject does not
  settle it for another. The same user on multiple devices shares SEEN by design.
  """

  import Ecto.Query

  alias Casein.Mobile.{AttentionCursor, AttentionTransition}
  alias Casein.Notifications.Notification
  alias Casein.Origin
  alias Casein.Repo

  @card "card"
  @session_window "session_window"
  @notification "notification"

  @type subject_kind :: :card | :session_window | :notification

  @type subject :: %{
          required(:kind) => subject_kind() | String.t(),
          required(:id) => String.t(),
          optional(:origin_id) => String.t()
        }

  @doc "Build a card subject from an attention key (stable `AttentionInbox.key/1`)."
  def card_subject(attention_key, origin_id \\ Origin.id())
      when is_binary(attention_key) and is_binary(origin_id) do
    %{kind: :card, id: attention_key, origin_id: origin_id}
  end

  @doc "Build a session-window subject for quiet / needs_you chrome."
  def session_window_subject(workspace_id, session_id, window_id, origin_id \\ Origin.id())
      when is_binary(workspace_id) and is_binary(session_id) and is_binary(window_id) and
             is_binary(origin_id) do
    %{
      kind: :session_window,
      id: "#{workspace_id}:session:#{session_id}:window:#{window_id}",
      origin_id: origin_id
    }
  end

  @doc "Build a notification-row subject (legacy / unbound drawer rows)."
  def notification_subject(notification_id, origin_id \\ Origin.id())
      when is_binary(notification_id) and is_binary(origin_id) do
    %{kind: :notification, id: notification_id, origin_id: origin_id}
  end

  @doc """
  Derive the best subject for a notification row.

  Prefers `metadata.attention_key` (card), then workspace+session session key,
  else the notification id.
  """
  def subject_for_notification(%Notification{} = n) do
    origin_id = metadata_string(n.metadata, "origin_id") || Origin.id()
    attention_key = metadata_string(n.metadata, "attention_key")

    cond do
      is_binary(attention_key) and attention_key != "" ->
        card_subject(attention_key, origin_id)

      is_binary(n.workspace_id) and is_binary(n.session_id) and n.session_id != "" ->
        card_subject("#{n.workspace_id}:session:#{n.session_id}", origin_id)

      true ->
        notification_subject(n.id, origin_id)
    end
  end

  @doc "Fetch the ack row for a user/subject, or nil."
  @spec get(String.t(), subject()) :: AttentionCursor.t() | nil
  def get(user_id, subject) when is_binary(user_id) and is_map(subject) do
    {kind, id, origin_id} = normalize_subject(subject)

    Repo.get_by(AttentionCursor,
      user_id: user_id,
      origin_id: origin_id,
      subject_kind: kind,
      card_id: id
    )
  end

  @doc "True when the user has SEEN this subject (any watermark / seen_at)."
  @spec seen?(String.t(), subject()) :: boolean()
  def seen?(user_id, subject) when is_binary(user_id) do
    match?(%AttentionCursor{viewed_at: %DateTime{}}, get(user_id, subject))
  end

  @doc "True when SEEN through at least `marker` (card watermarks)."
  @spec seen_through?(String.t(), subject(), pos_integer()) :: boolean()
  def seen_through?(user_id, subject, marker)
      when is_binary(user_id) and is_integer(marker) and marker > 0 do
    case get(user_id, subject) do
      %AttentionCursor{through_transition_id: through} when is_integer(through) ->
        through >= marker

      _ ->
        false
    end
  end

  @doc "True when the user has RESOLVED this subject."
  @spec resolved?(String.t(), subject()) :: boolean()
  def resolved?(user_id, subject) when is_binary(user_id) do
    match?(%AttentionCursor{resolved_at: %DateTime{}}, get(user_id, subject))
  end

  @doc "True when not resolved (open work for this viewer)."
  @spec open?(String.t(), subject()) :: boolean()
  def open?(user_id, subject), do: not resolved?(user_id, subject)

  @doc """
  Advance SEEN for a subject.

  Options:

    * `:through` — monotonic watermark (card transitions). Advances with `max`.
    * `:now` — timestamp
    * `:sync_notifications` — when true (default for card subjects), mark matching
      notification rows read so the drawer settles with the phone
    * `:require_transition` — when true, `:through` must reference a transition
      owned by this user/origin/card (phone path)
  """
  @spec mark_seen(String.t(), subject(), keyword()) ::
          {:ok, AttentionCursor.t()} | {:error, term()}
  def mark_seen(user_id, subject, opts \\ [])

  def mark_seen(user_id, subject, opts) when is_binary(user_id) and is_map(subject) do
    if store_enabled?() do
      do_mark_seen(user_id, subject, opts)
    else
      {:error, :attention_store_unavailable}
    end
  end

  @doc """
  Mark RESOLVED (and SEEN) for a subject.

  Options: `:now`, `:sync_notifications` (default true for cards).
  """
  @spec mark_resolved(String.t(), subject(), keyword()) ::
          {:ok, AttentionCursor.t()} | {:error, term()}
  def mark_resolved(user_id, subject, opts \\ [])

  def mark_resolved(user_id, subject, opts) when is_binary(user_id) and is_map(subject) do
    if store_enabled?() do
      do_mark_resolved(user_id, subject, opts)
    else
      {:error, :attention_store_unavailable}
    end
  end

  @doc """
  SEEN for a card with an exact server-issued transition marker.

  Used by `AttentionInbox.mark_viewed/5`. Verifies transition ownership.
  """
  @spec mark_card_seen_through(String.t(), String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, AttentionCursor.t()} | {:error, term()}
  def mark_card_seen_through(user_id, origin_id, card_id, marker, opts \\ [])
      when is_binary(user_id) and is_binary(origin_id) and is_binary(card_id) and
             is_integer(marker) and marker > 0 do
    mark_seen(
      user_id,
      card_subject(card_id, origin_id),
      Keyword.merge(opts, through: marker, require_transition: true, sync_notifications: true)
    )
  end

  @doc """
  SEEN for a session window (web focus / click into quiet agent).

  Also SEEN-settles the session card subject when workspace+session are known.
  """
  @spec mark_session_window_seen(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          keyword()
        ) :: {:ok, AttentionCursor.t()} | {:error, term()}
  def mark_session_window_seen(user_id, workspace_id, session_id, window_id, opts \\ [])
      when is_binary(user_id) and is_binary(workspace_id) and is_binary(session_id) and
             is_binary(window_id) do
    origin_id = Keyword.get(opts, :origin_id, Origin.id())
    subject = session_window_subject(workspace_id, session_id, window_id, origin_id)

    with {:ok, ack} <- mark_seen(user_id, subject, opts) do
      _ =
        mark_seen(
          user_id,
          card_subject("#{workspace_id}:session:#{session_id}", origin_id),
          Keyword.put(opts, :sync_notifications, true)
        )

      {:ok, ack}
    end
  end

  @doc """
  One-shot backfill: project existing notification read/resolved rows into ack.

  Safe to re-run (merge-by-max). Used by deploy/ops and the migration test so
  drawer state does not mass-unread after the schema lands.
  """
  @spec backfill_from_notifications(keyword()) :: %{
          seen: non_neg_integer(),
          resolved: non_neg_integer()
        }
  def backfill_from_notifications(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now()) |> to_usec()

    notifications =
      from(n in Notification,
        where: not is_nil(n.read_at) or not is_nil(n.resolved_at)
      )
      |> Repo.all()

    Enum.reduce(notifications, %{seen: 0, resolved: 0}, fn n, acc ->
      subject = subject_for_notification(n)
      seen_at = n.read_at || n.resolved_at || now

      case mark_seen(n.user_id, subject, now: seen_at, sync_notifications: false) do
        {:ok, _} ->
          acc = %{acc | seen: acc.seen + 1}

          if n.resolved_at do
            _ = mark_resolved(n.user_id, subject, now: n.resolved_at, sync_notifications: false)
            %{acc | resolved: acc.resolved + 1}
          else
            acc
          end

        {:error, _} ->
          acc
      end
    end)
  end

  defp do_mark_seen(user_id, subject, opts) do
    {kind, id, origin_id} = normalize_subject(subject)
    now = opts |> Keyword.get(:now, DateTime.utc_now()) |> to_usec()
    through = Keyword.get(opts, :through)
    require_transition? = Keyword.get(opts, :require_transition, false)
    sync? = Keyword.get(opts, :sync_notifications, kind == @card)

    Repo.transaction(fn ->
      through =
        cond do
          require_transition? and is_integer(through) and through > 0 ->
            ensure_transition!(user_id, origin_id, id, through)
            through

          is_integer(through) and through > 0 ->
            through

          kind == @card ->
            latest_transition_id(user_id, origin_id, id) || 1

          true ->
            1
        end

      ack = upsert_seen!(user_id, origin_id, kind, id, through, now)

      if sync?, do: sync_notifications_read!(user_id, kind, id, origin_id, now)

      ack
    end)
  end

  defp do_mark_resolved(user_id, subject, opts) do
    {kind, id, origin_id} = normalize_subject(subject)
    now = opts |> Keyword.get(:now, DateTime.utc_now()) |> to_usec()
    sync? = Keyword.get(opts, :sync_notifications, kind == @card)

    Repo.transaction(fn ->
      through = latest_transition_id(user_id, origin_id, id) || 1
      ack = upsert_seen!(user_id, origin_id, kind, id, through, now)

      ack =
        if is_nil(ack.resolved_at) do
          ack
          |> AttentionCursor.changeset(%{resolved_at: now})
          |> Repo.update!()
        else
          ack
        end

      if sync?, do: sync_notifications_resolved!(user_id, kind, id, origin_id, now)

      ack
    end)
  end

  defp ensure_transition!(user_id, origin_id, card_id, marker) do
    transition =
      Repo.one(
        from t in AttentionTransition,
          where:
            t.id == ^marker and t.user_id == ^user_id and t.origin_id == ^origin_id and
              t.card_id == ^card_id
      )

    if is_nil(transition), do: Repo.rollback(:invalid_attention_marker)
    transition
  end

  defp latest_transition_id(user_id, origin_id, card_id) do
    Repo.one(
      from t in AttentionTransition,
        where: t.user_id == ^user_id and t.origin_id == ^origin_id and t.card_id == ^card_id,
        order_by: [desc: t.id],
        limit: 1,
        select: t.id
    )
  end

  defp upsert_seen!(user_id, origin_id, kind, id, through, now) do
    attrs = %{
      user_id: user_id,
      origin_id: origin_id,
      subject_kind: kind,
      card_id: id,
      through_transition_id: through,
      viewed_at: now
    }

    %AttentionCursor{}
    |> AttentionCursor.changeset(attrs)
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:user_id, :origin_id, :subject_kind, :card_id]
    )

    cursor_query =
      from c in AttentionCursor,
        where:
          c.user_id == ^user_id and c.origin_id == ^origin_id and c.subject_kind == ^kind and
            c.card_id == ^id

    cursor =
      if sqlite?() do
        Repo.one!(cursor_query)
      else
        cursor_query |> lock("FOR UPDATE") |> Repo.one!()
      end

    new_through =
      if is_integer(through) and through > (cursor.through_transition_id || 0),
        do: through,
        else: cursor.through_transition_id

    new_viewed = max_dt(cursor.viewed_at, now)

    if new_through == cursor.through_transition_id and new_viewed == cursor.viewed_at do
      cursor
    else
      cursor
      |> AttentionCursor.changeset(%{
        through_transition_id: new_through,
        viewed_at: new_viewed
      })
      |> Repo.update!()
    end
  end

  defp sync_notifications_read!(user_id, kind, subject_id, origin_id, now) do
    user_id
    |> matching_notifications(kind, subject_id, origin_id)
    |> Enum.each(fn
      %Notification{read_at: nil} = n ->
        n
        |> Ecto.Changeset.change(%{read_at: now})
        |> Repo.update()

      _ ->
        :ok
    end)
  end

  defp sync_notifications_resolved!(user_id, kind, subject_id, origin_id, now) do
    user_id
    |> matching_notifications(kind, subject_id, origin_id)
    |> Enum.each(fn n ->
      changes =
        %{}
        |> Map.put(:resolved_at, n.resolved_at || now)
        |> Map.put(:read_at, n.read_at || now)

      n
      |> Ecto.Changeset.change(changes)
      |> Repo.update()
    end)
  end

  defp matching_notifications(user_id, kind, subject_id, origin_id) do
    from(n in Notification, where: n.user_id == ^user_id)
    |> Repo.all()
    |> Enum.filter(&notification_matches_subject?(&1, kind, subject_id, origin_id))
  end

  defp notification_matches_subject?(n, @card, attention_key, origin_id) do
    meta_key = metadata_string(n.metadata, "attention_key")
    meta_origin = metadata_string(n.metadata, "origin_id")
    session_id = session_id_from_attention_key(attention_key)

    cond do
      meta_key == attention_key and (is_nil(meta_origin) or meta_origin == origin_id) ->
        true

      meta_key in [nil, ""] and is_binary(session_id) and session_id != "" and
          n.session_id == session_id ->
        true

      true ->
        false
    end
  end

  defp notification_matches_subject?(n, @notification, notification_id, _origin_id) do
    n.id == notification_id
  end

  defp notification_matches_subject?(n, @session_window, subject_id, _origin_id) do
    case Regex.run(~r/^(.+):session:([^:]+):window:/, subject_id) do
      [_, workspace_id, session_id] ->
        n.workspace_id == workspace_id and n.session_id == session_id

      _ ->
        false
    end
  end

  defp session_id_from_attention_key(key) when is_binary(key) do
    case Regex.run(~r/:session:(.+)$/, key) do
      [_, session_id] -> session_id
      _ -> ""
    end
  end

  defp normalize_subject(subject) when is_map(subject) do
    kind =
      normalize_kind(Map.get(subject, :kind) || Map.get(subject, "kind"))

    id =
      case Map.get(subject, :id) || Map.get(subject, "id") do
        id when is_binary(id) and id != "" -> id
        _ -> raise ArgumentError, "acknowledgement subject requires id"
      end

    origin_id =
      Map.get(subject, :origin_id) || Map.get(subject, "origin_id") || Origin.id()

    {kind, id, origin_id}
  end

  defp normalize_kind(kind) when kind in [:card, "card"], do: @card
  defp normalize_kind(kind) when kind in [:session_window, "session_window"], do: @session_window
  defp normalize_kind(kind) when kind in [:notification, "notification"], do: @notification
  defp normalize_kind(_), do: raise(ArgumentError, "invalid acknowledgement subject kind")

  defp metadata_string(meta, key) when is_map(meta) do
    case Map.get(meta, key) || Map.get(meta, String.to_existing_atom(key)) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  rescue
    ArgumentError ->
      case Map.get(meta, key) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
  end

  defp metadata_string(_, _), do: nil

  defp max_dt(nil, b), do: b
  defp max_dt(a, nil), do: a

  defp max_dt(a, b) do
    if DateTime.compare(a, b) == :gt, do: a, else: b
  end

  defp to_usec(%DateTime{microsecond: {usec, _}} = datetime),
    do: %{datetime | microsecond: {usec, 6}}

  defp sqlite? do
    Atom.to_string(Repo.__adapter__()) == "Elixir.Ecto.Adapters.SQLite3"
  end

  defp store_enabled? do
    Application.get_env(:casein, :mobile_attention_store_enabled, true) != false
  end
end
