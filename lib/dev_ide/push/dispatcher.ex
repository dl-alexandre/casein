defmodule DevIDE.Push.Dispatcher do
  @moduledoc """
  Listens to the audit and mobile-card spines and turns high-signal events into
  OS pushes.

  Unlike `DevIdeWeb.SessionChannel` (which delivers in-app banners only while a
  device is connected), the dispatcher runs server-side regardless of any live
  connection — that's the point of OS push: reach a backgrounded/killed app.

  Audit subscriptions are lazy: `DevIDE.Push.Registry` calls `watch/1` when a
  token is registered for a workspace, so the dispatcher only listens where
  there's a device to notify. Mobile card events are already user-scoped by the
  observer, so the dispatcher filters registered devices by `user_id`.
  """
  use GenServer

  require Logger

  alias DevIDE.Mobile.UserObserver
  alias DevIDE.{Alerts, Audit, Notifications, Push}

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{watched: MapSet.new()}, name: __MODULE__)
  end

  @doc """
  Subscribe to a workspace's audit events (idempotent). Synchronous so the
  subscription is in place before the caller proceeds — an alert emitted
  immediately after registering a token must not be missed.
  """
  @spec watch(String.t()) :: :ok
  def watch(workspace_id) when is_binary(workspace_id) do
    GenServer.call(__MODULE__, {:watch, workspace_id})
  end

  @impl true
  def init(state) do
    Phoenix.PubSub.subscribe(DevIde.PubSub, UserObserver.card_events_topic())
    {:ok, state}
  end

  @impl true
  def handle_call({:watch, workspace_id}, _from, %{watched: watched} = state) do
    if MapSet.member?(watched, workspace_id) do
      {:reply, :ok, state}
    else
      :ok = Audit.subscribe(workspace_id)
      {:reply, :ok, %{state | watched: MapSet.put(watched, workspace_id)}}
    end
  end

  @impl true
  def handle_info({:audit_event, %{action: "run.approval_requested"}}, state) do
    # Review pushes are emitted from observer card creation so they follow the
    # user-specific card lifecycle and do not duplicate audit-alert pushes.
    {:noreply, state}
  end

  def handle_info({:audit_event, event}, state) do
    case Alerts.notification_for(event) do
      nil -> :ok
      notification -> dispatch(event, notification)
    end

    {:noreply, state}
  end

  def handle_info({:mobile_card_created, card}, state) do
    case mobile_card_notification(card) do
      nil -> :ok
      notification -> dispatch_mobile_card(card, notification)
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp dispatch(event, notification) do
    provider = Push.provider()

    for entry <- Push.tokens_for(event.workspace_id) do
      case Task.Supervisor.start_child(DevIDE.TaskSupervisor, fn ->
             deliver_alert(provider, event, entry, notification)
           end) do
        {:ok, _pid} ->
          :ok

        {:error, reason} ->
          Logger.warning("failed to start push delivery task: #{inspect(reason)}")
      end
    end
  end

  defp dispatch_mobile_card(card, notification) do
    provider = Push.provider()

    entries =
      card.user_id
      |> Push.tokens_for_user()
      |> Kernel.++(Push.tokens_for(card.workspace_id))
      |> Enum.filter(&mobile_card_recipient?(&1, card))
      |> Enum.uniq_by(&{&1.platform, &1.token})

    for entry <- entries do
      case Task.Supervisor.start_child(DevIDE.TaskSupervisor, fn ->
             deliver_mobile_card(provider, entry, notification, card)
           end) do
        {:ok, _pid} ->
          :ok

        {:error, reason} ->
          Logger.warning("failed to start mobile card push delivery task: #{inspect(reason)}")
      end
    end
  end

  defp mobile_card_notification(%{type: :needs_review, priority: :high} = card) do
    %{
      workspace_id: card.workspace_id,
      user_id: card.user_id,
      session_id: card.session_id,
      card_id: card.id,
      card_type: Atom.to_string(card.type),
      action: "mobile.needs_review",
      title: card.title,
      reason: card.body,
      at: card.created_at,
      deep_link: "devide://review/#{URI.encode_www_form(card.id)}"
    }
  end

  defp mobile_card_notification(_card), do: nil

  defp mobile_card_recipient?(%{user_id: user_id}, %{user_id: card_user_id})
       when is_binary(user_id) and is_binary(card_user_id) do
    user_id == card_user_id
  end

  defp mobile_card_recipient?(_entry, _card), do: false

  defp deliver_alert(provider, event, %{user_id: user_id} = entry, notification)
       when is_binary(user_id) do
    case Notifications.deliver_alert_event(event, user_id) do
      {:ok, durable, _status} ->
        if Notifications.channel_enabled?(durable, "push") do
          deliver(provider, entry, Map.put(notification, :notification_id, durable.id))
        else
          :ok
        end

      :ignored ->
        :ok

      {:error, changeset} ->
        Logger.warning("failed to persist alert notification: #{inspect(changeset.errors)}")
        deliver(provider, entry, notification)
    end
  end

  defp deliver_alert(provider, _event, entry, notification) do
    deliver(provider, entry, notification)
  end

  defp deliver_mobile_card(provider, entry, notification, card) do
    if card_push_allowed?(card) do
      deliver(provider, entry, maybe_put_notification_id(notification, card))
    else
      :ok
    end
  end

  defp card_push_allowed?(%{meta: %{push_allowed: false}}), do: false
  defp card_push_allowed?(%{meta: %{"push_allowed" => false}}), do: false
  defp card_push_allowed?(_card), do: true

  defp maybe_put_notification_id(notification, %{meta: meta}) when is_map(meta) do
    case Map.get(meta, :notification_id) || Map.get(meta, "notification_id") do
      id when is_binary(id) -> Map.put(notification, :notification_id, id)
      _ -> notification
    end
  end

  defp maybe_put_notification_id(notification, _card), do: notification

  defp deliver(provider, %{token: token, platform: platform}, notification) do
    emit_push(:attempt, platform, notification)

    case provider.push(token, platform, notification) do
      :ok ->
        emit_push(:success, platform, notification)
        :ok

      {:error, reason} = error ->
        Push.record_failure(token, reason)
        Logger.warning("push provider #{inspect(provider)} returned #{inspect(error)}")
        emit_push(:failure, platform, notification, reason)
        error
    end
  rescue
    e ->
      Push.record_failure(token, {:exception, e.__struct__})
      emit_push(:failure, platform, notification, e.__struct__)
      Logger.warning("push provider #{inspect(provider)} crashed: #{inspect(e)}")
  end

  defp emit_push(operation, platform, notification, reason \\ nil) do
    :telemetry.execute(
      [:dev_ide, :push, :delivery],
      %{count: 1},
      %{
        operation: operation,
        platform: platform,
        action: notification[:action],
        workspace_id: notification[:workspace_id],
        notification_id: notification[:notification_id],
        reason: inspect(reason)
      }
    )
  end
end
