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
  alias DevIDE.{Alerts, Audit, Push}

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
      notification -> dispatch(event.workspace_id, notification)
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

  defp dispatch(workspace_id, notification) do
    provider = Push.provider()

    for entry <- Push.tokens_for(workspace_id) do
      case Task.Supervisor.start_child(DevIDE.TaskSupervisor, fn ->
             deliver(provider, entry, notification)
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
             deliver(provider, entry, notification)
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

  defp deliver(provider, %{token: token, platform: platform}, notification) do
    case provider.push(token, platform, notification) do
      :ok ->
        :ok

      {:error, reason} = error ->
        if invalid_token_error?(reason), do: Push.unregister(token)
        Logger.warning("push provider #{inspect(provider)} returned #{inspect(error)}")
        error
    end
  rescue
    e ->
      Logger.warning("push provider #{inspect(provider)} crashed: #{inspect(e)}")
  end

  defp invalid_token_error?(:invalid_token), do: true
  defp invalid_token_error?({:invalid_token, _reason}), do: true
  defp invalid_token_error?({:fcm_status, status}) when status in [404, 410], do: true
  defp invalid_token_error?({:apns_status, status, _reason}) when status in [400, 410], do: true
  defp invalid_token_error?(_reason), do: false
end
