defmodule DevIDE.Mobile.UserObserver do
  @moduledoc """
  Per-user mobile card observer.

  One process owns the current mobile-facing card set for one user. Runtime
  systems still own execution, authorization, and business logic; the observer
  only translates already-authorized facts into a compact snapshot for mobile.
  """

  use GenServer

  alias DevIDE.Audit
  alias DevIDE.Audit.Event
  alias DevIDE.Mobile.Card
  alias DevIDE.Notifications
  alias DevIDE.Workspaces.State

  @registry DevIDE.Mobile.UserObserverRegistry
  @supervisor DevIDE.Mobile.UserObserverSupervisor
  @topic_prefix "mobile:user:"
  @card_events_topic "mobile:cards"
  @telemetry_prefix [:dev_ide, :mobile]

  @type snapshot :: %{
          user_id: String.t(),
          version: non_neg_integer(),
          cards: [Card.t()]
        }

  def child_spec(opts) do
    user_id = Keyword.fetch!(opts, :user_id)

    %{
      id: {__MODULE__, user_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  def start_link(opts) do
    user_id = Keyword.fetch!(opts, :user_id)
    GenServer.start_link(__MODULE__, user_id, name: via(user_id))
  end

  @spec ensure_started(String.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(user_id) when is_binary(user_id) do
    case Registry.lookup(@registry, user_id) do
      [{pid, _value}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(@supervisor, {__MODULE__, user_id: user_id}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, _reason} = error -> error
        end
    end
  end

  @spec topic(String.t()) :: String.t()
  def topic(user_id) when is_binary(user_id), do: @topic_prefix <> user_id

  @spec card_events_topic() :: String.t()
  def card_events_topic, do: @card_events_topic

  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(user_id) when is_binary(user_id) do
    Phoenix.PubSub.subscribe(DevIDE.PubSub, topic(user_id))
  end

  @spec snapshot(String.t()) :: snapshot()
  def snapshot(user_id) when is_binary(user_id) do
    {:ok, _pid} = ensure_started(user_id)
    GenServer.call(via(user_id), :snapshot)
  end

  @doc """
  Start observing a workspace's audit spine for this user.

  Authorization is intentionally outside this module. Callers that know the
  user may see the workspace ask the observer to subscribe; the observer only
  consumes the facts after that decision.
  """
  @spec watch_workspace(String.t(), String.t()) :: :ok | {:error, term()}
  def watch_workspace(user_id, workspace_id)
      when is_binary(user_id) and is_binary(workspace_id) do
    {:ok, _pid} = ensure_started(user_id)
    GenServer.call(via(user_id), {:watch_workspace, workspace_id})
  end

  @spec needs_review_changed(String.t(), map()) :: :ok
  def needs_review_changed(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    cast_card_event(user_id, {:needs_review_changed, attrs})
  end

  @spec in_progress_changed(String.t(), map()) :: :ok
  def in_progress_changed(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    cast_card_event(user_id, {:in_progress_changed, attrs})
  end

  @spec in_progress_cleared(String.t(), map()) :: :ok
  def in_progress_cleared(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    cast_card_event(user_id, {:remove, :in_progress, attrs, "in_progress_cleared"})
  end

  @spec connection_issue_changed(String.t(), map()) :: :ok
  def connection_issue_changed(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    cast_card_event(user_id, {:connection_issue_changed, attrs})
  end

  @spec workspace_idle_changed(String.t(), map()) :: :ok
  def workspace_idle_changed(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    cast_card_event(user_id, {:workspace_idle_changed, attrs})
  end

  @spec workspace_idle_cleared(String.t(), map()) :: :ok
  def workspace_idle_cleared(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    cast_card_event(user_id, {:remove, :workspace_idle, attrs, "workspace_idle_cleared"})
  end

  @spec connection_live(String.t(), String.t()) :: :ok
  def connection_live(user_id, workspace_id)
      when is_binary(user_id) and is_binary(workspace_id) do
    cast_card_event(
      user_id,
      {:remove, :connection_issue, %{workspace_id: workspace_id}, "connection_live"}
    )
  end

  @spec clear(String.t()) :: :ok
  def clear(user_id) when is_binary(user_id) do
    {:ok, _pid} = ensure_started(user_id)
    GenServer.call(via(user_id), :clear)
  end

  @spec stop(String.t()) :: :ok
  def stop(user_id) when is_binary(user_id) do
    case Registry.lookup(@registry, user_id) do
      [{pid, _value}] -> GenServer.call(pid, :stop)
      [] -> :ok
    end
  end

  @impl true
  def init(user_id) do
    state = %{user_id: user_id, version: 0, cards: %{}, watched_workspaces: MapSet.new()}
    emit([:user_observer, :start], %{count: 1}, %{user_id: user_id, observer_pid: self()})
    {:ok, state}
  end

  @impl true
  def terminate(reason, state) do
    emit([:user_observer, :stop], %{count: 1}, %{
      user_id: state.user_id,
      observer_pid: self(),
      reason: reason
    })
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, snapshot_payload(state), state}
  end

  def handle_call(:clear, _from, state) do
    state =
      state
      |> unsubscribe_all()
      |> Map.merge(%{version: state.version + 1, cards: %{}, watched_workspaces: MapSet.new()})

    broadcast(state)
    {:reply, :ok, state}
  end

  def handle_call(:stop, _from, state) do
    {:stop, :normal, :ok, unsubscribe_all(state)}
  end

  def handle_call({:watch_workspace, workspace_id}, _from, state) do
    if MapSet.member?(state.watched_workspaces, workspace_id) do
      {:reply, :ok, state}
    else
      :ok = Audit.subscribe(workspace_id)

      {:reply, :ok,
       %{state | watched_workspaces: MapSet.put(state.watched_workspaces, workspace_id)}}
    end
  end

  @impl true
  def handle_cast({:needs_review_changed, attrs}, state) do
    attrs = Map.put(attrs, :user_id, state.user_id)

    state =
      case Card.needs_review(attrs, now()) do
        nil -> remove_card(state, :needs_review, attrs, "needs_review_changed")
        card -> upsert_card(state, card, "needs_review_changed")
      end

    {:noreply, state}
  end

  def handle_cast({:in_progress_changed, attrs}, state) do
    attrs = Map.put(attrs, :user_id, state.user_id)
    {:noreply, upsert_card(state, Card.in_progress(attrs, now()), "in_progress_changed")}
  end

  def handle_cast({:connection_issue_changed, attrs}, state) do
    attrs = Map.put(attrs, :user_id, state.user_id)

    {:noreply,
     upsert_card(state, Card.connection_issue(attrs, now()), "connection_issue_changed")}
  end

  def handle_cast({:workspace_idle_changed, attrs}, state) do
    attrs = Map.put(attrs, :user_id, state.user_id)

    state =
      case Card.workspace_idle(attrs, now()) do
        nil -> remove_card(state, :workspace_idle, attrs, "workspace_idle_changed")
        card -> upsert_card(state, card, "workspace_idle_changed")
      end

    {:noreply, state}
  end

  def handle_cast({:remove, type, attrs, source}, state) do
    {:noreply, remove_card(state, type, Map.put(attrs, :user_id, state.user_id), source)}
  end

  @impl true
  def handle_info({:audit_event, %Event{} = event}, state) do
    _ = Notifications.deliver_alert_event(event, state.user_id)
    {:noreply, handle_audit_event(state, event)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_audit_event(state, %Event{action: "run.approval_requested"} = event) do
    attrs = event_card_attrs(state.user_id, event) |> Map.put(:review_count, review_count(event))

    case Card.needs_review(attrs, event.inserted_at) do
      nil -> state
      card -> upsert_card(state, card, event.action)
    end
  end

  defp handle_audit_event(state, %Event{} = event)
       when event.action in ["run.approval_granted", "run.approval_denied"] do
    remove_card(state, :needs_review, event_card_attrs(state.user_id, event), event.action)
  end

  defp handle_audit_event(state, %Event{action: "run.started"} = event) do
    state.user_id
    |> event_card_attrs(event)
    |> Map.merge(%{
      command: meta(event, "command_line") || meta(event, "command_id"),
      run_phase: "executing",
      started_at: event.inserted_at,
      last_activity_at: event.inserted_at
    })
    |> Card.in_progress(event.inserted_at)
    |> then(&upsert_card(state, &1, event.action))
  end

  defp handle_audit_event(state, %Event{} = event)
       when event.action in ["run.succeeded", "run.failed", "run.timed_out"] do
    remove_card(state, :in_progress, event_card_attrs(state.user_id, event), event.action)
  end

  defp handle_audit_event(state, _event), do: state

  defp upsert_card(state, card, source) do
    key = Card.key(card)
    existing = Map.get(state.cards, key)
    operation = if(existing, do: :update, else: :create)
    now = now()
    card = Card.merge_update(existing, card, now)
    card = maybe_persist_card_created(card, operation)
    state = %{state | version: state.version + 1, cards: Map.put(state.cards, key, card)}
    emit_card(:upsert, card, source, operation: operation)
    maybe_broadcast_card_created(card, operation)
    broadcast(state)
    state
  end

  defp remove_card(state, type, attrs, source) do
    workspace_id = attrs[:workspace_id] || attrs["workspace_id"]
    session_id = attrs[:session_id] || attrs["session_id"]
    key = {state.user_id, workspace_id, session_id, type}

    case Map.fetch(state.cards, key) do
      {:ok, card} ->
        state = %{state | version: state.version + 1, cards: Map.delete(state.cards, key)}
        emit_card(:remove, card, source)
        broadcast(state)
        state

      :error ->
        state
    end
  end

  defp unsubscribe_all(state) do
    Enum.each(state.watched_workspaces, fn workspace_id ->
      Phoenix.PubSub.unsubscribe(DevIDE.PubSub, Audit.topic(workspace_id))
    end)

    %{state | watched_workspaces: MapSet.new()}
  end

  defp cast_card_event(user_id, event) do
    {:ok, _pid} = ensure_started(user_id)
    GenServer.cast(via(user_id), event)
    :ok
  end

  defp snapshot_payload(state) do
    %{
      user_id: state.user_id,
      version: state.version,
      cards: state.cards |> Map.values() |> Card.order()
    }
  end

  defp broadcast(state) do
    payload = snapshot_payload(state)
    started_at = System.monotonic_time()

    Phoenix.PubSub.broadcast(
      DevIDE.PubSub,
      topic(state.user_id),
      {:mobile_cards_snapshot, payload}
    )

    emit(
      [:snapshot, :broadcast],
      %{count: 1, duration: System.monotonic_time() - started_at},
      %{user_id: state.user_id, version: state.version, card_count: length(payload.cards)}
    )
  end

  defp maybe_broadcast_card_created(card, :create) do
    Phoenix.PubSub.broadcast(
      DevIDE.PubSub,
      @card_events_topic,
      {:mobile_card_created, card}
    )
  end

  defp maybe_broadcast_card_created(_card, _operation), do: :ok

  defp maybe_persist_card_created(card, :create) do
    case Notifications.deliver_mobile_card(card) do
      {:ok, notification, _status} ->
        meta =
          card.meta
          |> Map.put(:notification_id, notification.id)
          |> Map.put(:push_allowed, Notifications.channel_enabled?(notification, "push"))

        %{card | meta: meta}

      _ ->
        card
    end
  end

  defp maybe_persist_card_created(card, _operation), do: card

  defp event_card_attrs(user_id, %Event{} = event) do
    workspace_id = event.workspace_id
    session_id = meta(event, "session_id") || meta(event, "run_id") || event.target_ref

    %{
      user_id: user_id,
      workspace_id: workspace_id,
      workspace_name: workspace_name(workspace_id),
      session_id: session_id,
      command_id: meta(event, "command_id"),
      approval_id: meta(event, "approval_id"),
      actor_id: event.actor_id,
      reason: event.reason || meta(event, "reason"),
      source: event.action,
      target_ref: event.target_ref,
      last_activity_at: event.inserted_at,
      agent_reasoning: first_meta(event, ["agent_reasoning", "reasoning", "summary"]),
      diff_preview: meta(event, "diff_preview"),
      files_changed: first_meta(event, ["files_changed", "changed_files"]),
      previous_decisions: first_meta(event, ["previous_decisions", "decision_history"])
    }
  end

  defp review_count(%Event{} = event) do
    case meta(event, "review_count") || meta(event, "pending_reviews") do
      value when is_integer(value) and value > 0 -> value
      value when is_binary(value) -> parse_positive(value)
      _ -> 1
    end
  end

  defp parse_positive(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> 1
    end
  end

  defp workspace_name(nil), do: nil

  defp workspace_name(workspace_id) do
    case State.get(workspace_id) do
      {:ok, %{name: name}} when is_binary(name) and name != "" -> name
      _ -> workspace_id
    end
  end

  defp meta(%Event{metadata: metadata}, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(metadata, key)
  end

  defp meta(_event, _key), do: nil

  defp first_meta(event, keys) do
    Enum.find_value(keys, &meta(event, &1))
  end

  defp now, do: DateTime.utc_now()

  defp via(user_id), do: {:via, Registry, {@registry, user_id}}

  defp emit(event, measurements, metadata) do
    :telemetry.execute(@telemetry_prefix ++ event, measurements, metadata)
  end

  defp emit_card(action, card, source, extra \\ []) do
    emit([:card, action], %{count: 1}, %{
      user_id: card.user_id,
      card_type: card.type,
      workspace_id: card.workspace_id,
      session_id: card.session_id,
      source: source,
      priority: card.priority,
      operation: Keyword.get(extra, :operation)
    })
  end
end
