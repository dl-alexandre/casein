defmodule Casein.Notifications do
  @moduledoc """
  Durable notification inbox and delivery event spine.

  This context is intentionally smaller than the final notification system: it
  persists normalized notification rows, dedupes bursts, and broadcasts durable
  lifecycle changes. Push-device persistence and user preferences can plug into
  this contract in later slices.
  """

  import Ecto.Query

  alias Casein.Audit.Event
  alias Casein.Alerts
  alias Casein.Attention.Acknowledgement
  alias Casein.Attention.Delivery
  alias Casein.Mobile.{AttentionInbox, ResumeCard}
  alias Casein.Notifications.Notification
  alias Casein.Origin
  alias Casein.Notifications.Preference
  alias Casein.Repo

  @topic_prefix "notifications:user:"
  @default_limit 50
  @max_limit 200
  @default_dedupe_window_seconds 300
  @quiet_channels ~w(push browser mobile)

  @type delivery_status :: :created | :deduped

  @doc "Subscribe to durable notification changes for one user."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(user_id) when is_binary(user_id) do
    Phoenix.PubSub.subscribe(Casein.PubSub, topic(user_id))
  end

  @spec topic(String.t()) :: String.t()
  def topic(user_id) when is_binary(user_id), do: @topic_prefix <> user_id

  @doc """
  Persist a notification and broadcast it unless a recent duplicate exists.

  Options:

    * `:dedupe_window_seconds` - look back this many seconds for the same
      `{user_id, dedupe_key}`. Defaults to `0`, which disables dedupe.
    * `:now` - deterministic timestamp for tests and callers that already have
      an event timestamp.
  """
  @spec deliver(map(), keyword()) ::
          {:ok, Notification.t(), delivery_status()} | {:error, Ecto.Changeset.t()}
  def deliver(attrs, opts \\ []) when is_map(attrs) do
    now = opts |> Keyword.get(:now, DateTime.utc_now()) |> to_usec()
    attrs = prepare_attrs(attrs, now)
    dedupe_window_seconds = dedupe_window_seconds(attrs, opts)

    case recent_duplicate(attrs, dedupe_window_seconds, now) do
      %Notification{} = notification ->
        notification = group_duplicate(notification, attrs, now)
        emit_delivery(notification, :deduped)
        {:ok, notification, :deduped}

      nil ->
        %Notification{}
        |> Notification.changeset(attrs)
        |> Repo.insert()
        |> case do
          {:ok, notification} ->
            broadcast(notification, {:notification_created, notification})
            emit_delivery(notification, :created)
            {:ok, notification, :created}

          {:error, _changeset} = error ->
            error
        end
    end
  end

  @doc "Build durable notification attrs from an alert-worthy audit event."
  @spec attrs_from_alert_event(Event.t(), String.t()) :: map() | nil
  def attrs_from_alert_event(%Event{} = event, user_id) when is_binary(user_id) do
    Alerts.notification_attrs_for(event, user_id)
  end

  @doc "Build, policy-filter, persist, and broadcast a durable alert notification."
  @spec deliver_alert_event(Event.t(), String.t(), keyword()) ::
          {:ok, Notification.t(), delivery_status()} | {:error, Ecto.Changeset.t()} | :ignored
  def deliver_alert_event(%Event{} = event, user_id, opts \\ []) when is_binary(user_id) do
    case attrs_from_alert_event(event, user_id) do
      nil ->
        :ignored

      attrs ->
        attrs
        |> apply_preferences(opts)
        |> deliver(
          opts
          |> Keyword.put_new(
            :dedupe_window_seconds,
            fetch_attr(attrs, :dedupe_window_seconds) || @default_dedupe_window_seconds
          )
        )
    end
  end

  @doc "Persist a durable notification for a mobile card creation."
  @spec deliver_mobile_card(map(), keyword()) ::
          {:ok, Notification.t(), delivery_status()} | {:error, Ecto.Changeset.t()} | :ignored
  def deliver_mobile_card(card, opts \\ []) when is_map(card) do
    case mobile_card_attrs(card) do
      nil ->
        :ignored

      attrs ->
        attrs
        |> apply_preferences(opts)
        |> deliver(
          opts
          |> Keyword.put_new(
            :dedupe_window_seconds,
            fetch_attr(attrs, :dedupe_window_seconds) || @default_dedupe_window_seconds
          )
        )
    end
  end

  @doc "List recent notifications for a user."
  @spec list_for_user(String.t(), keyword()) :: [Notification.t()]
  def list_for_user(user_id, opts \\ []) when is_binary(user_id) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp_limit()

    Notification
    |> where([n], n.user_id == ^user_id)
    |> maybe_unread_only(Keyword.get(opts, :unread_only, false))
    |> maybe_open_only(Keyword.get(opts, :open_only, false))
    |> order_by([n], desc: n.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Count unread, unresolved notifications for a user."
  @spec unread_count(String.t()) :: non_neg_integer()
  # Served by notifications_user_unread_index
  # (user_id WHERE read_at IS NULL AND resolved_at IS NULL) (#926).
  def unread_count(user_id) when is_binary(user_id) do
    Notification
    |> where([n], n.user_id == ^user_id)
    |> where([n], is_nil(n.read_at) and is_nil(n.resolved_at))
    |> Repo.aggregate(:count)
  end

  @doc "Return effective channel names after defaults, preferences, and quiet hours."
  @spec effective_channels(map() | Notification.t(), keyword()) :: [String.t()]
  def effective_channels(attrs_or_notification, opts \\ []) do
    channels =
      attrs_or_notification
      |> fetch_field(:channels)
      |> normalize_channels()

    user_id = fetch_field(attrs_or_notification, :user_id)
    workspace_id = fetch_field(attrs_or_notification, :workspace_id)
    type = fetch_field(attrs_or_notification, :type)
    default_delivery = fetch_field(attrs_or_notification, :default_delivery) || %{}
    now = opts |> Keyword.get(:now, DateTime.utc_now()) |> to_usec()

    preference =
      Keyword.get_lazy(opts, :preferences, fn ->
        if is_binary(user_id), do: effective_preferences(user_id, workspace_id), else: nil
      end)

    channels
    |> Enum.filter(&default_channel_enabled?(default_delivery, &1))
    |> Enum.filter(&preference_channel_enabled?(preference, type, &1))
    |> reject_quiet_channels(preference, now)
  end

  @doc "True when a persisted or attrs-map notification should route to a channel."
  @spec channel_enabled?(map() | Notification.t(), String.t() | atom()) :: boolean()
  def channel_enabled?(attrs_or_notification, channel) do
    channel = string_value(channel)
    channel in normalize_channels(fetch_field(attrs_or_notification, :channels))
  end

  @doc "Fetch persisted preferences, returning an unsaved default struct when absent."
  @spec get_preferences(String.t(), String.t() | nil) :: Preference.t()
  def get_preferences(user_id, workspace_id \\ nil) when is_binary(user_id) do
    workspace_id = preference_workspace_id(workspace_id)

    Repo.get_by(Preference, user_id: user_id, workspace_id: workspace_id) ||
      %Preference{user_id: user_id, workspace_id: workspace_id, settings: %{}, quiet_hours: %{}}
  end

  @doc "Create or replace a user's notification preferences for a workspace/global scope."
  @spec put_preferences(String.t(), map()) :: {:ok, Preference.t()} | {:error, Ecto.Changeset.t()}
  def put_preferences(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    attrs =
      attrs
      |> put_attr(:user_id, user_id)
      |> put_attr(:workspace_id, preference_workspace_id(fetch_attr(attrs, :workspace_id)))

    %Preference{}
    |> Preference.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:settings, :quiet_hours, :updated_at]},
      conflict_target: [:user_id, :workspace_id],
      returning: true
    )
  end

  @spec mark_read(String.t(), String.t(), keyword()) ::
          {:ok, Notification.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def mark_read(id, user_id, opts \\ []) do
    # SEEN is the cross-surface fact; the notification row projects read_at.
    update_lifecycle_with_ack(id, user_id, :read_at, opts)
  end

  @doc """
  Mark every unread, unresolved notification for a user as read in one
  `UPDATE`. Mirrors the drawer mark-all filters (`unread_only` + `open_only`).

  Returns the number of rows updated. Broadcasts a single
  `{:notification_updated, :mark_all_read}` so connected viewers refresh
  without an N-row PubSub fan-out. Also SEEN-settles each row's acknowledgement
  subject so phone / session surfaces quiet with the drawer.
  """
  @spec mark_all_read(String.t(), keyword()) :: non_neg_integer()
  def mark_all_read(user_id, opts \\ []) when is_binary(user_id) do
    now = opts |> Keyword.get(:now, DateTime.utc_now()) |> to_usec()

    open =
      from(n in Notification,
        where: n.user_id == ^user_id and is_nil(n.read_at) and is_nil(n.resolved_at)
      )
      |> Repo.all()

    {count, _} =
      from(n in Notification,
        where: n.user_id == ^user_id and is_nil(n.read_at) and is_nil(n.resolved_at)
      )
      |> Repo.update_all(set: [read_at: now])

    # One SEEN upsert per unique subject — not per notification row (#922).
    # Do not re-introduce Enum.each(open, mark_seen) without uniq_by; 500 unread
    # on the same card must not open 500 transactions.
    open
    |> Enum.map(&Acknowledgement.subject_for_notification/1)
    |> Enum.uniq_by(fn subject ->
      {Map.get(subject, :kind), Map.get(subject, :id), Map.get(subject, :origin_id)}
    end)
    |> Enum.each(fn subject ->
      _ =
        Acknowledgement.mark_seen(user_id, subject,
          now: now,
          sync_notifications: false
        )
    end)

    if count > 0 do
      Phoenix.PubSub.broadcast(
        Casein.PubSub,
        topic(user_id),
        {:notification_updated, :mark_all_read}
      )
    end

    count
  end

  @spec resolve(String.t(), String.t(), keyword()) ::
          {:ok, Notification.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def resolve(id, user_id, opts \\ []) do
    # RESOLVED (implies SEEN) is the cross-surface fact.
    update_lifecycle_with_ack(id, user_id, :resolved_at, opts)
  end

  @spec mute(String.t(), String.t(), keyword()) ::
          {:ok, Notification.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def mute(id, user_id, opts \\ []), do: update_lifecycle(id, user_id, :muted_at, opts)

  defp prepare_attrs(attrs, now) do
    attrs
    |> maybe_put_expires_at(now)
    |> put_attr_new(:occurrence_count, 1)
    |> put_attr_new(:last_seen_at, now)
    |> put_attr(:channels, effective_channels(attrs, now: now))
  end

  defp maybe_put_expires_at(attrs, now) do
    if fetch_attr(attrs, :expires_at) do
      attrs
    else
      case ttl_seconds(fetch_attr(attrs, :ttl_seconds)) do
        ttl when is_integer(ttl) and ttl > 0 ->
          put_attr(attrs, :expires_at, DateTime.add(now, ttl, :second))

        _ ->
          attrs
      end
    end
  end

  defp recent_duplicate(_attrs, window, _now) when window <= 0, do: nil

  defp recent_duplicate(attrs, window, now) do
    with user_id when is_binary(user_id) <- fetch_attr(attrs, :user_id),
         dedupe_key when is_binary(dedupe_key) <- fetch_attr(attrs, :dedupe_key) do
      cutoff = DateTime.add(now, -window, :second)

      Notification
      |> where([n], n.user_id == ^user_id)
      |> where([n], n.dedupe_key == ^dedupe_key)
      |> where([n], n.inserted_at >= ^cutoff)
      |> where([n], is_nil(n.resolved_at))
      |> order_by([n], desc: n.inserted_at)
      |> limit(1)
      |> Repo.one()
    else
      _ -> nil
    end
  end

  defp group_duplicate(%Notification{} = notification, attrs, now) do
    current_count = notification.occurrence_count || 1
    metadata = notification.metadata || %{}

    metadata =
      metadata
      |> Map.put("occurrence_count", current_count + 1)
      |> maybe_put_grouped_reason(fetch_attr(attrs, :body))
      |> maybe_put_grouped_metadata(fetch_attr(attrs, :metadata))

    notification
    |> Ecto.Changeset.change(%{
      occurrence_count: current_count + 1,
      last_seen_at: now,
      metadata: metadata
    })
    |> Repo.update()
    |> case do
      {:ok, notification} ->
        broadcast(notification, {:notification_updated, notification})
        notification

      {:error, _changeset} ->
        notification
    end
  end

  defp update_lifecycle_with_ack(id, user_id, field, opts) do
    now = opts |> Keyword.get(:now, DateTime.utc_now()) |> to_usec()

    case Repo.get_by(Notification, id: id, user_id: user_id) do
      nil ->
        {:error, :not_found}

      %Notification{} = notification ->
        changes =
          case field do
            :resolved_at -> [{field, now}, {:read_at, notification.read_at || now}]
            _ -> [{field, now}]
          end

        notification
        |> Ecto.Changeset.change(changes)
        |> Repo.update()
        |> case do
          {:ok, notification} ->
            subject = Acknowledgement.subject_for_notification(notification)

            _ =
              case field do
                :resolved_at ->
                  Acknowledgement.mark_resolved(user_id, subject,
                    now: now,
                    sync_notifications: false
                  )

                :read_at ->
                  Acknowledgement.mark_seen(user_id, subject,
                    now: now,
                    sync_notifications: false
                  )

                _ ->
                  :ok
              end

            broadcast(notification, {:notification_updated, notification})
            {:ok, notification}

          {:error, _changeset} = error ->
            error
        end
    end
  end

  defp update_lifecycle(id, user_id, field, opts) do
    now = opts |> Keyword.get(:now, DateTime.utc_now()) |> to_usec()

    case Repo.get_by(Notification, id: id, user_id: user_id) do
      nil ->
        {:error, :not_found}

      %Notification{} = notification ->
        notification
        |> Ecto.Changeset.change([{field, now}])
        |> Repo.update()
        |> case do
          {:ok, notification} ->
            broadcast(notification, {:notification_updated, notification})
            {:ok, notification}

          {:error, _changeset} = error ->
            error
        end
    end
  end

  defp maybe_unread_only(query, true), do: where(query, [n], is_nil(n.read_at))
  defp maybe_unread_only(query, _), do: query

  defp maybe_open_only(query, true), do: where(query, [n], is_nil(n.resolved_at))
  defp maybe_open_only(query, _), do: query

  defp broadcast(%Notification{user_id: user_id}, message) when is_binary(user_id) do
    Phoenix.PubSub.broadcast(Casein.PubSub, topic(user_id), message)
  end

  defp emit_delivery(%Notification{} = notification, operation) do
    :telemetry.execute(
      [:casein, :notifications, :deliver],
      %{count: 1},
      %{
        operation: operation,
        type: notification.type,
        severity: notification.severity,
        user_id: notification.user_id,
        workspace_id: notification.workspace_id
      }
    )
  end

  defp apply_preferences(attrs, opts) do
    put_attr(attrs, :channels, effective_channels(attrs, opts))
  end

  defp dedupe_window_seconds(attrs, opts) do
    opts
    |> Keyword.get(:dedupe_window_seconds, fetch_attr(attrs, :dedupe_window_seconds))
    |> ttl_seconds()
    |> case do
      ttl when is_integer(ttl) and ttl > 0 -> ttl
      _ -> 0
    end
  end

  defp ttl_seconds(value) when is_integer(value), do: value

  defp ttl_seconds(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp ttl_seconds(_value), do: nil

  defp mobile_card_attrs(card) do
    attention = AttentionInbox.project(card)

    # Threshold: Casein.Attention.Delivery.drawer_eligible?/1 (rank floor 400).
    if Delivery.drawer_eligible?(attention), do: mobile_attention_attrs(card, attention)
  end

  defp mobile_attention_attrs(card, attention) do
    user_id = card_field(card, :user_id)
    workspace_id = card_field(card, :workspace_id)
    session_id = card_field(card, :session_id)
    id = card_field(card, :id)
    origin = Origin.public_descriptor()

    %{
      user_id: user_id,
      workspace_id: workspace_id,
      session_id: session_id,
      type: mobile_notification_type(card),
      severity: Delivery.drawer_severity(attention.priority),
      title: mobile_attention_title(card),
      body: mobile_attention_body(card),
      metadata: %{
        "card_id" => id,
        "attention_key" => attention.key,
        "card_type" => string_value(card_field(card, :type)),
        "priority" => attention.priority,
        "reason_code" => attention.reason_code,
        "required_decision" => attention.required_decision,
        "origin_id" => origin.id,
        "origin_name" => origin.display_name
      },
      dedupe_key: "#{user_id}:#{attention.notification_group}",
      ttl_seconds: 86_400,
      dedupe_window_seconds: 600,
      deep_link: ResumeCard.deep_link(card),
      channels: ["in_app", "push", "mobile"],
      default_delivery: %{"in_app" => true, "push" => true, "mobile" => true},
      source_type: "mobile_card",
      source_id: id
    }
  end

  defp mobile_attention_title(card) do
    if card_field(card, :type) in [:clarification, "clarification"],
      do: "Casein needs your attention",
      else: card_field(card, :title) || "Casein needs your attention"
  end

  defp mobile_attention_body(card) do
    if card_field(card, :type) in [:clarification, "clarification"],
      do: "An agent is waiting for your response",
      else: card_field(card, :body)
  end

  defp mobile_notification_type(card) do
    case card_field(card, :type) do
      type when type in [:needs_review, "needs_review"] -> "needs_review"
      _type -> "mobile_attention"
    end
  end

  defp card_field(card, key) when is_atom(key) do
    Map.get(card, key) || Map.get(card, Atom.to_string(key))
  end

  defp normalize_channels(nil), do: []

  defp normalize_channels(channels) when is_list(channels) do
    channels
    |> Enum.map(&string_value/1)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  defp normalize_channels(channel), do: normalize_channels([channel])

  defp default_channel_enabled?(default_delivery, channel) when is_map(default_delivery) do
    case map_get(default_delivery, channel) do
      false -> false
      "false" -> false
      _ -> true
    end
  end

  defp default_channel_enabled?(_default_delivery, _channel), do: true

  defp preference_channel_enabled?(nil, _type, _channel), do: true

  defp preference_channel_enabled?(%Preference{settings: settings}, type, channel) do
    case preference_channel_value(settings, type, channel) do
      false -> false
      "false" -> false
      _ -> true
    end
  end

  defp preference_channel_value(settings, type, channel) when is_map(settings) do
    type = string_value(type)

    settings
    |> map_get("types")
    |> case do
      types when is_map(types) ->
        types
        |> map_get(type)
        |> case do
          %{} = by_type -> by_type |> map_get("channels") |> map_get(channel)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp preference_channel_value(_settings, _type, _channel), do: nil

  defp reject_quiet_channels(channels, nil, _now), do: channels

  defp reject_quiet_channels(channels, %Preference{quiet_hours: quiet_hours}, now) do
    if quiet_now?(quiet_hours, now) do
      Enum.reject(channels, &(&1 in @quiet_channels))
    else
      channels
    end
  end

  defp quiet_now?(%{"enabled" => enabled} = quiet_hours, now) when enabled in [true, "true"] do
    with {:ok, start_time} <- quiet_time(map_get(quiet_hours, "start")),
         {:ok, end_time} <- quiet_time(map_get(quiet_hours, "end")) do
      current = DateTime.to_time(now)

      if Time.compare(start_time, end_time) == :gt do
        Time.compare(current, start_time) != :lt or Time.compare(current, end_time) == :lt
      else
        Time.compare(current, start_time) != :lt and Time.compare(current, end_time) == :lt
      end
    else
      _ -> false
    end
  end

  defp quiet_now?(_quiet_hours, _now), do: false

  defp quiet_time(value) when is_binary(value) do
    case Time.from_iso8601(value) do
      {:ok, time} -> {:ok, time}
      {:error, _} -> Time.from_iso8601(value <> ":00")
    end
  end

  defp quiet_time(_value), do: :error

  defp preference_workspace_id(workspace_id) when workspace_id in [nil, ""],
    do: Preference.global_workspace_id()

  defp preference_workspace_id(workspace_id), do: workspace_id

  defp effective_preferences(user_id, workspace_id) do
    global = get_preferences(user_id)
    workspace_key = preference_workspace_id(workspace_id)

    if workspace_key == Preference.global_workspace_id() do
      global
    else
      case Repo.get_by(Preference, user_id: user_id, workspace_id: workspace_key) do
        nil ->
          global

        %Preference{} = workspace ->
          %Preference{
            workspace
            | settings: deep_merge(global.settings || %{}, workspace.settings || %{}),
              quiet_hours: Map.merge(global.quiet_hours || %{}, workspace.quiet_hours || %{})
          }
      end
    end
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value),
        do: deep_merge(left_value, right_value),
        else: right_value
    end)
  end

  defp maybe_put_grouped_reason(metadata, reason) when reason in [nil, ""], do: metadata
  defp maybe_put_grouped_reason(metadata, reason), do: Map.put(metadata, "last_reason", reason)

  defp maybe_put_grouped_metadata(metadata, grouped_metadata) when grouped_metadata in [nil, %{}],
    do: metadata

  defp maybe_put_grouped_metadata(metadata, grouped_metadata),
    do: Map.put(metadata, "last_metadata", normalize_json_map(grouped_metadata))

  defp normalize_json_map(value) do
    value
    |> Jason.encode!()
    |> Jason.decode!()
  rescue
    _ -> %{}
  end

  defp clamp_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(@max_limit)

  defp clamp_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {int, ""} -> clamp_limit(int)
      _ -> @default_limit
    end
  end

  defp clamp_limit(_limit), do: @default_limit

  defp fetch_attr(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp fetch_field(%Notification{} = notification, key), do: Map.get(notification, key)
  defp fetch_field(%{} = attrs, key), do: fetch_attr(attrs, key)
  defp fetch_field(_value, _key), do: nil

  defp put_attr(attrs, key, value) do
    if Map.has_key?(attrs, Atom.to_string(key)),
      do: Map.put(attrs, Atom.to_string(key), value),
      else: Map.put(attrs, key, value)
  end

  defp put_attr_new(attrs, key, value) do
    if fetch_attr(attrs, key) do
      attrs
    else
      put_attr(attrs, key, value)
    end
  end

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, string_value(key))
  end

  defp map_get(_map, _key), do: nil

  defp string_value(nil), do: nil
  defp string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp string_value(value), do: to_string(value)

  defp to_usec(%DateTime{microsecond: {usec, _precision}} = datetime) do
    %{datetime | microsecond: {usec, 6}}
  end
end
