defmodule Casein.Push.Dispatcher do
  @moduledoc """
  Delivers OS pushes for alert-worthy audit events (via
  `Casein.Signals.AlertsRouter`) and high-priority mobile-card events.

  Unlike `CaseinWeb.SessionChannel` (which delivers in-app banners only while a
  device is connected), the dispatcher runs server-side regardless of any live
  connection — that's the point of OS push: reach a backgrounded/killed app.

  Workspace alert watches are lazy: `Casein.Push.Registry` calls
  `Casein.Signals.AlertsRouter.watch/1` when a token is registered. Mobile card
  events are already user-scoped by the observer, so the dispatcher filters
  registered devices by `user_id`.
  """
  use GenServer

  require Logger

  alias Casein.Audit.Event
  alias Casein.Attention.Delivery
  alias Casein.Mobile.{AttentionInbox, Observability}
  alias Casein.Mobile.UserObserver
  alias Casein.Mobile.ResumeCard
  alias Casein.Origin
  alias Casein.Workspaces.State
  alias Casein.{Alerts, Notifications, Push}

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Deliver an alert-worthy audit event to registered push tokens for its workspace.

  Called by `Casein.Signals.AlertsRouter` after signal-bus routing; synchronous
  so a token registered immediately before an alert is not missed.
  """
  @spec deliver_audit_alert(Event.t()) :: :ok
  def deliver_audit_alert(%Event{} = event) do
    GenServer.call(__MODULE__, {:deliver_audit_alert, event})
  end

  @impl true
  def init(state) do
    Phoenix.PubSub.subscribe(Casein.PubSub, UserObserver.card_events_topic())
    {:ok, state}
  end

  @impl true
  def handle_call({:deliver_audit_alert, event}, _from, state) do
    case Alerts.notification_for(event) do
      nil -> :ok
      notification -> dispatch(event, notification)
    end

    {:reply, :ok, state}
  end

  @impl true
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
    notification = Map.put(notification, :workspace_name, workspace_name(event.workspace_id))

    event.workspace_id
    |> Push.tokens_for()
    |> Enum.group_by(&alert_recipient_group/1)
    |> Enum.each(fn
      {{:user, user_id}, entries} ->
        dispatch_user_alert(provider, event, user_id, entries, notification)

      {{:token, _platform, _token}, entries} ->
        dispatch_entries(provider, entries, notification)
    end)
  end

  defp dispatch_entries(provider, entries, notification) do
    Enum.each(entries, fn entry ->
      case Task.Supervisor.start_child(Casein.TaskSupervisor, fn ->
             deliver(provider, entry, notification)
           end) do
        {:ok, _pid} ->
          :ok

        {:error, reason} ->
          Logger.warning("failed to start push delivery task: #{inspect(reason)}")
      end
    end)
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
      case Task.Supervisor.start_child(Casein.TaskSupervisor, fn ->
             deliver_mobile_card(provider, entry, notification, card)
           end) do
        {:ok, _pid} ->
          :ok

        {:error, reason} ->
          Logger.warning("failed to start mobile card push delivery task: #{inspect(reason)}")
      end
    end
  end

  defp mobile_card_notification(card) do
    attention = AttentionInbox.project(card)
    resume = ResumeCard.project(card)

    # Threshold: Casein.Attention.Delivery.push_eligible?/1 — stricter than
    # cockpit `session_needs_you?` (H28). Rank floor 400 AND signal in
    # push_signals/0 (excludes :idle quiet-window and :agent_stalled).
    # Channel prefs / quiet hours / push_allowed still apply outside this gate.
    if Delivery.push_eligible?(attention) do
      %{
        workspace_id: card.workspace_id,
        workspace_name: card.workspace_name,
        user_id: card.user_id,
        session_id: card.session_id,
        card_id: card.id,
        attention_key: attention.key,
        card_type: Atom.to_string(card.type),
        action: mobile_push_action(card),
        title: card.title,
        reason: mobile_push_reason(card, attention),
        reason_code: attention.reason_code,
        required_decision: attention.required_decision,
        notification_group: attention.notification_group,
        at: card.created_at,
        locator: resume.locator,
        resume_state: resume.state,
        resume_phase: resume.phase,
        deep_link: ResumeCard.deep_link(card)
      }
    end
  end

  defp mobile_push_action(%{type: :needs_review}), do: "mobile.needs_review"
  defp mobile_push_action(%{type: :clarification}), do: "mobile.attention"
  defp mobile_push_action(_card), do: "mobile.attention"

  defp mobile_push_reason(%{type: :needs_review, body: body}, _attention)
       when is_binary(body),
       do: body

  defp mobile_push_reason(%{type: :clarification}, _attention),
    do: "An agent is waiting for your response"

  defp mobile_push_reason(_card, attention), do: attention.explanation

  defp mobile_card_recipient?(%{user_id: user_id}, %{user_id: card_user_id})
       when is_binary(user_id) and is_binary(card_user_id) do
    user_id == card_user_id
  end

  defp mobile_card_recipient?(_entry, _card), do: false

  defp dispatch_user_alert(provider, event, user_id, entries, notification) do
    case Notifications.deliver_alert_event(event, user_id) do
      {:ok, durable, status} ->
        if alert_push_allowed?(durable, status, event) do
          dispatch_entries(
            provider,
            entries,
            Map.put(notification, :notification_id, durable.id)
          )
        else
          maybe_observe_alert_dedupe(durable, status, event, List.first(entries))
          :ok
        end

      :ignored ->
        :ok

      {:error, changeset} ->
        Logger.warning("failed to persist alert notification: #{inspect(changeset.errors)}")
        dispatch_entries(provider, entries, notification)
    end
  end

  # A push that does not name its workspace is unactionable when several
  # workspaces are running: the operator cannot tell which one wants them.
  # Mobile cards already carry the name; audit alerts only carry the id.
  defp workspace_name(nil), do: nil

  defp workspace_name(workspace_id) when is_binary(workspace_id) do
    case State.get(workspace_id) do
      {:ok, %{name: name}} when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  defp workspace_name(_workspace_id), do: nil

  defp alert_recipient_group(%{user_id: user_id}) when is_binary(user_id),
    do: {:user, user_id}

  defp alert_recipient_group(entry), do: {:token, entry.platform, entry.token}

  # The user observer may persist the exact audit event before the push
  # dispatcher sees it. That row is reported as deduped, but it is still the
  # first delivery of this source event. A later event grouped into the same
  # row has a different source id and must not produce another OS push.
  defp alert_push_allowed?(durable, status, event) do
    Notifications.channel_enabled?(durable, "push") and
      (status == :created or
         (is_binary(event.id) and durable.source_id == event.id))
  end

  defp maybe_observe_alert_dedupe(durable, :deduped, event, entry) when is_map(entry) do
    if is_binary(event.id) and durable.source_id != event.id do
      Observability.record(
        %{
          user_id: entry.user_id,
          workspace_id: event.workspace_id,
          origin_id: Origin.id(),
          platform: entry.platform
        },
        %{"event" => "notification", "outcome" => "deduped"}
      )
    end
  end

  defp maybe_observe_alert_dedupe(_durable, _status, _event, _entry), do: :ok

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
    notification =
      notification
      |> Map.put(:origin_id, Origin.id())
      |> Map.put(:origin_name, Origin.display_name())

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
      [:casein, :push, :delivery],
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
