defmodule DevIDE.Notifications do
  @moduledoc """
  Durable notification inbox and delivery event spine.

  This context is intentionally smaller than the final notification system: it
  persists normalized notification rows, dedupes bursts, and broadcasts durable
  lifecycle changes. Push-device persistence and user preferences can plug into
  this contract in later slices.
  """

  import Ecto.Query

  alias DevIDE.Audit.Event
  alias DevIDE.Alerts
  alias DevIDE.Notifications.Notification
  alias DevIde.Repo

  @topic_prefix "notifications:user:"
  @default_limit 50
  @max_limit 200

  @type delivery_status :: :created | :deduped

  @doc "Subscribe to durable notification changes for one user."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(user_id) when is_binary(user_id) do
    Phoenix.PubSub.subscribe(DevIde.PubSub, topic(user_id))
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
  def unread_count(user_id) when is_binary(user_id) do
    Notification
    |> where([n], n.user_id == ^user_id)
    |> where([n], is_nil(n.read_at) and is_nil(n.resolved_at))
    |> Repo.aggregate(:count)
  end

  @spec mark_read(String.t(), String.t(), keyword()) ::
          {:ok, Notification.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def mark_read(id, user_id, opts \\ []), do: update_lifecycle(id, user_id, :read_at, opts)

  @spec resolve(String.t(), String.t(), keyword()) ::
          {:ok, Notification.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def resolve(id, user_id, opts \\ []), do: update_lifecycle(id, user_id, :resolved_at, opts)

  @spec mute(String.t(), String.t(), keyword()) ::
          {:ok, Notification.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def mute(id, user_id, opts \\ []), do: update_lifecycle(id, user_id, :muted_at, opts)

  defp prepare_attrs(attrs, now) do
    attrs
    |> maybe_put_expires_at(now)
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
    Phoenix.PubSub.broadcast(DevIde.PubSub, topic(user_id), message)
  end

  defp emit_delivery(%Notification{} = notification, operation) do
    :telemetry.execute(
      [:dev_ide, :notifications, :deliver],
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

  defp put_attr(attrs, key, value) do
    if Map.has_key?(attrs, Atom.to_string(key)),
      do: Map.put(attrs, Atom.to_string(key), value),
      else: Map.put(attrs, key, value)
  end

  defp to_usec(%DateTime{microsecond: {usec, _precision}} = datetime) do
    %{datetime | microsecond: {usec, 6}}
  end
end
