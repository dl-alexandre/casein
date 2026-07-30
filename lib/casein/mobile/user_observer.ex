defmodule Casein.Mobile.UserObserver do
  @moduledoc """
  Per-user mobile card observer.

  One process owns the current mobile-facing card set for one user. Runtime
  systems still own execution, authorization, and business logic; the observer
  only translates already-authorized facts into a compact snapshot for mobile.
  """

  use GenServer

  alias Casein.Audit
  alias Casein.Audit.Event
  alias Casein.Mobile.AttentionInbox
  alias Casein.Mobile.Card
  alias Casein.Mobile.Clarification
  alias Casein.Mobile.LiveWork
  alias Casein.Mobile.ResumeCard
  alias Casein.Notifications
  alias Casein.Push
  alias Casein.Terminals.SessionDirectory
  alias Casein.Workspaces.State

  @registry Casein.Mobile.UserObserverRegistry
  @supervisor Casein.Mobile.UserObserverSupervisor
  @topic_prefix "mobile:user:"
  @card_events_topic "mobile:cards"
  @telemetry_prefix [:casein, :mobile]

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
    Phoenix.PubSub.subscribe(Casein.PubSub, topic(user_id))
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

  @doc false
  @spec reconcile_live_work(String.t(), String.t(), list()) :: snapshot()
  def reconcile_live_work(user_id, workspace_id, tabs)
      when is_binary(user_id) and is_binary(workspace_id) and is_list(tabs) do
    {:ok, _pid} = ensure_started(user_id)
    GenServer.call(via(user_id), {:reconcile_live_work, workspace_id, tabs})
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

  @doc """
  Re-broadcast the current authoritative cards without changing their version.

  Cursor updates use this to refresh all connected devices after a shared
  viewed-through marker advances.
  """
  @spec refresh(String.t()) :: :ok
  def refresh(user_id) when is_binary(user_id) do
    {:ok, _pid} = ensure_started(user_id)
    GenServer.cast(via(user_id), :refresh)
  end

  @spec stop(String.t()) :: :ok
  def stop(user_id) when is_binary(user_id) do
    case Registry.lookup(@registry, user_id) do
      [{pid, _value}] ->
        try do
          GenServer.call(pid, :stop)
        catch
          :exit, {:noproc, _call} -> :ok
        end

      [] ->
        :ok
    end
  end

  @impl true
  def init(user_id) do
    state = %{
      user_id: user_id,
      version: 0,
      cards: %{},
      watched_workspaces: MapSet.new(),
      live_work_seen: MapSet.new(),
      live_work_hydrations: %{},
      clarification_hydrations: %{}
    }

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
      |> Map.merge(%{
        version: state.version + 1,
        cards: %{},
        watched_workspaces: MapSet.new(),
        live_work_seen: MapSet.new(),
        live_work_hydrations: %{},
        clarification_hydrations: %{}
      })

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
      :ok = SessionDirectory.subscribe(workspace_id, workspace_name: workspace_name(workspace_id))
      :ok = Clarification.subscribe(workspace_id)
      hydration_ref = make_ref()
      clarification_ref = make_ref()
      hydrate_live_work_async(self(), workspace_id, hydration_ref)
      hydrate_clarifications_async(self(), workspace_id, clarification_ref)

      {:reply, :ok,
       %{
         state
         | watched_workspaces: MapSet.put(state.watched_workspaces, workspace_id),
           live_work_hydrations: Map.put(state.live_work_hydrations, workspace_id, hydration_ref),
           clarification_hydrations:
             Map.put(state.clarification_hydrations, workspace_id, clarification_ref)
       }}
    end
  end

  def handle_call({:reconcile_live_work, workspace_id, tabs}, _from, state) do
    state = reconcile_live_work_state(state, workspace_id, tabs)
    {:reply, snapshot_payload(state), state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    broadcast(state)
    {:noreply, state}
  end

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
    _ = maybe_deliver_alert_event(event, state.user_id)
    state = handle_audit_event(state, event)
    state = apply_lifecycle_transition(state, record_lifecycle_event(state, event))
    {:noreply, state}
  end

  def handle_info(
        {SessionDirectory, {:sessions_updated, workspace_id, tabs}},
        state
      ) do
    if MapSet.member?(state.watched_workspaces, workspace_id) do
      was_hydrating = Map.has_key?(state.live_work_hydrations, workspace_id)

      state = %{
        state
        | live_work_seen: MapSet.put(state.live_work_seen, workspace_id),
          live_work_hydrations: Map.delete(state.live_work_hydrations, workspace_id)
      }

      next_state = reconcile_live_work_state(state, workspace_id, tabs)
      if was_hydrating and next_state.version == state.version, do: broadcast(next_state)
      {:noreply, next_state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:live_work_hydrated, workspace_id, hydration_ref, tabs}, state) do
    current_ref = Map.get(state.live_work_hydrations, workspace_id)

    if MapSet.member?(state.watched_workspaces, workspace_id) and
         current_ref == hydration_ref and
         not MapSet.member?(state.live_work_seen, workspace_id) do
      state = %{
        state
        | live_work_hydrations: Map.delete(state.live_work_hydrations, workspace_id)
      }

      next_state = reconcile_live_work_state(state, workspace_id, tabs)
      if next_state.version == state.version, do: broadcast(next_state)
      {:noreply, next_state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:clarification_requested, event}, state) do
    if MapSet.member?(state.watched_workspaces, event.workspace_id) do
      card = Clarification.card(event, state.user_id, workspace_name(event.workspace_id))

      state = invalidate_clarification_hydration(state, event.workspace_id)
      {:noreply, upsert_card(state, card, event.event_type)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:clarification_resolved, request_event_id, event}, state) do
    state = invalidate_clarification_hydration(state, event.workspace_id)
    {:noreply, remove_clarification(state, request_event_id, "agent.clarification_resolved")}
  end

  def handle_info(
        {:clarifications_hydrated, workspace_id, hydration_ref, events},
        state
      ) do
    if Map.get(state.clarification_hydrations, workspace_id) == hydration_ref and
         MapSet.member?(state.watched_workspaces, workspace_id) do
      state = %{
        state
        | clarification_hydrations: Map.delete(state.clarification_hydrations, workspace_id)
      }

      next_state =
        Enum.reduce(events, state, fn event, acc ->
          card = Clarification.card(event, acc.user_id, workspace_name(workspace_id))

          upsert_card(acc, card, "agent.clarification_hydrated",
            broadcast?: false,
            persist_notification?: false
          )
        end)

      if next_state.version > state.version, do: broadcast(next_state)
      {:noreply, next_state}
    else
      {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_audit_event(state, %Event{action: "run.approval_requested"} = event) do
    attrs = event_card_attrs(state.user_id, event) |> Map.put(:review_count, review_count(event))

    case Card.needs_review(attrs, event.inserted_at) do
      nil ->
        state

      card ->
        state
        |> delete_card_without_broadcast(:in_progress, attrs)
        |> upsert_card(card, event.action, event: event)
    end
  end

  defp handle_audit_event(state, %Event{} = event)
       when event.action in ["run.approval_granted", "run.approval_denied"] do
    _ = record_resolution_transition(state, event)
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
    attrs =
      state.user_id
      |> event_card_attrs(event)
      |> Map.merge(%{
        outcome: String.replace_prefix(event.action, "run.", ""),
        source: event.action,
        last_activity_at: event.inserted_at,
        merge_sha: meta(event, "merge_sha"),
        deploy_sha: first_meta(event, ["deploy_sha", "deployed_sha"]),
        verification: first_meta(event, ["verification", "checks"])
      })

    state
    |> delete_card_without_broadcast(:in_progress, attrs)
    |> delete_card_without_broadcast(:needs_review, attrs)
    |> upsert_card(Card.outcome(attrs, event.inserted_at), event.action, event: event)
  end

  defp handle_audit_event(state, _event), do: state

  defp upsert_card(state, card, source, opts \\ []) do
    key = Card.key(card)
    existing = Map.get(state.cards, key)
    operation = if(existing, do: :update, else: :create)
    now = now()
    card = Card.merge_update(existing, card, now)

    card =
      if Keyword.get(opts, :persist_notification?, true),
        do: maybe_persist_card_created(card, operation),
        else: card

    _ = record_card_transition(card, source, opts)
    state = %{state | version: state.version + 1, cards: Map.put(state.cards, key, card)}
    emit_card(:upsert, card, source, operation: operation)
    maybe_broadcast_card_created(card, operation)
    if Keyword.get(opts, :broadcast?, true), do: broadcast(state)
    state
  end

  defp remove_clarification(state, request_event_id, source) do
    case Enum.find(state.cards, fn {_key, card} ->
           card.type == :clarification and
             Clarification.request_event_id(card) == request_event_id
         end) do
      {key, card} ->
        state = %{state | version: state.version + 1, cards: Map.delete(state.cards, key)}
        emit_card(:remove, card, source)
        broadcast(state)
        state

      nil ->
        state
    end
  end

  defp invalidate_clarification_hydration(state, workspace_id) when is_binary(workspace_id) do
    %{
      state
      | clarification_hydrations: Map.delete(state.clarification_hydrations, workspace_id)
    }
  end

  defp invalidate_clarification_hydration(state, _workspace_id), do: state

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

  defp delete_card_without_broadcast(state, type, attrs) do
    workspace_id = attrs[:workspace_id] || attrs["workspace_id"]
    session_id = attrs[:session_id] || attrs["session_id"]
    key = {state.user_id, workspace_id, session_id, type}
    %{state | cards: Map.delete(state.cards, key)}
  end

  defp unsubscribe_all(state) do
    Enum.each(state.watched_workspaces, fn workspace_id ->
      Phoenix.PubSub.unsubscribe(Casein.PubSub, Audit.topic(workspace_id))
      Phoenix.PubSub.unsubscribe(Casein.PubSub, Clarification.topic(workspace_id))
      SessionDirectory.unsubscribe(workspace_id)
    end)

    %{state | watched_workspaces: MapSet.new()}
  end

  defp hydrate_live_work_async(observer, workspace_id, hydration_ref) do
    Task.Supervisor.start_child(Casein.TaskSupervisor, fn ->
      tabs = SessionDirectory.tabs(workspace_id, workspace_name: workspace_name(workspace_id))
      send(observer, {:live_work_hydrated, workspace_id, hydration_ref, tabs})
    end)

    :ok
  end

  defp hydrate_clarifications_async(observer, workspace_id, hydration_ref) do
    Task.Supervisor.start_child(Casein.TaskSupervisor, fn ->
      events = Clarification.open_for_workspace(workspace_id)
      send(observer, {:clarifications_hydrated, workspace_id, hydration_ref, events})
    end)

    :ok
  end

  defp reconcile_live_work_state(state, workspace_id, tabs) do
    projected =
      LiveWork.project(
        state.user_id,
        workspace_id,
        workspace_name(workspace_id),
        tabs,
        now()
      )

    existing_live =
      state.cards
      |> Enum.filter(fn {_key, card} ->
        card.workspace_id == workspace_id and card.source == "live_work"
      end)
      |> Map.new()

    projected_by_key =
      projected
      |> Enum.reject(fn card ->
        case Map.get(state.cards, Card.key(card)) do
          %{source: source} when source != "live_work" -> true
          _card -> false
        end
      end)
      |> Map.new(&{Card.key(&1), &1})

    next_cards =
      state.cards
      |> Map.drop(Map.keys(existing_live))
      |> Map.merge(projected_by_key)

    if live_fingerprint(existing_live) == live_fingerprint(projected_by_key) do
      state
    else
      next_cards =
        Enum.reduce(projected_by_key, next_cards, fn {key, card}, cards ->
          case Map.get(existing_live, key) do
            %{created_at: created_at} ->
              Map.put(cards, key, %{card | created_at: created_at})

            _missing ->
              cards
          end
        end)

      record_live_work_transitions(existing_live, next_cards, projected_by_key)

      state = %{state | version: state.version + 1, cards: next_cards}
      broadcast(state)
      state
    end
  end

  defp record_live_work_transitions(existing_live, next_cards, projected_by_key) do
    Enum.each(projected_by_key, fn {key, _projected_card} ->
      card = Map.fetch!(next_cards, key)

      if live_card_fingerprint(Map.get(existing_live, key)) != live_card_fingerprint(card) do
        _ = AttentionInbox.record_card(card, "live_work.reconciled")
      end
    end)

    existing_live
    |> Map.drop(Map.keys(projected_by_key))
    |> Enum.each(fn {_key, card} ->
      resume = ResumeCard.project(card)

      _ =
        AttentionInbox.record_card(card, "live_work.disappeared",
          state: resume.state,
          phase: resume.phase,
          reason_code: "offline_resumable",
          occurred_at: now()
        )
    end)
  end

  defp live_card_fingerprint(nil), do: nil

  defp live_card_fingerprint(card) do
    Map.take(card, [
      :source,
      :kind,
      :status,
      :title,
      :body,
      :context,
      :meta,
      :expires_at
    ])
  end

  defp live_fingerprint(cards) do
    cards
    |> Enum.map(fn {key, card} ->
      {key, live_card_fingerprint(card)}
    end)
    |> Enum.sort()
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
      hydrating_workspaces: Map.keys(state.live_work_hydrations),
      cards:
        state.cards
        |> Map.values()
        |> Enum.reject(&expired?/1)
        |> Card.order()
    }
  end

  defp broadcast(state) do
    payload = snapshot_payload(state)
    started_at = System.monotonic_time()

    Phoenix.PubSub.broadcast(
      Casein.PubSub,
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
      Casein.PubSub,
      @card_events_topic,
      {:mobile_card_created, card}
    )
  end

  defp maybe_broadcast_card_created(_card, _operation), do: :ok

  defp maybe_persist_card_created(card, :create) do
    case Notifications.deliver_mobile_card(card) do
      {:ok, notification, status} ->
        meta =
          card.meta
          |> Map.put(:notification_id, notification.id)
          |> Map.put(
            :push_allowed,
            status == :created and Notifications.channel_enabled?(notification, "push")
          )

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
      previous_decisions: first_meta(event, ["previous_decisions", "decision_history"]),
      locator:
        %{
          tmux_session: first_meta(event, ["tmux_session", "terminal_session"]),
          window: first_meta(event, ["window", "window_id"]),
          pane: first_meta(event, ["pane", "pane_id"]),
          tab: meta(event, "tab"),
          artifact: first_meta(event, ["artifact", "artifact_id"])
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()
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

  defp record_card_transition(card, source, opts) do
    case Keyword.get(opts, :event) do
      %Event{} = event ->
        AttentionInbox.record_card(card, source,
          event_id: event.id,
          occurred_at: event.inserted_at
        )

      _ ->
        AttentionInbox.record_card(card, source)
    end
  end

  # A registered user-scoped workspace token means Push.Dispatcher owns the
  # durable alert row and OS-delivery decision. Keeping one owner prevents the
  # observer and dispatcher from racing two identical notification inserts.
  defp maybe_deliver_alert_event(event, user_id) do
    if Enum.any?(Push.tokens_for(event.workspace_id), &(&1.user_id == user_id)) do
      :ok
    else
      Notifications.deliver_alert_event(event, user_id)
    end
  end

  defp record_lifecycle_event(state, %Event{} = event) do
    card = correlated_lifecycle_card(state, event)

    if is_map(card) do
      case AttentionInbox.record_card(
             card,
             event.action,
             [
               event_id: event.id,
               occurred_at: event.inserted_at
             ] ++ event_transition_opts(event)
           ) do
        {:ok, %Casein.Mobile.AttentionTransition{} = transition} ->
          {:ok, transition, Card.key(card)}

        result ->
          result
      end
    else
      {:ok, :unmatched}
    end
  end

  defp apply_lifecycle_transition(
         state,
         {:ok, %Casein.Mobile.AttentionTransition{} = transition, card_key}
       ) do
    card = Map.fetch!(state.cards, card_key)

    card =
      %{card | updated_at: latest_datetime(card.updated_at, transition.occurred_at)}
      |> Map.update!(:meta, fn meta ->
        Map.put(meta, :attention_transition, AttentionInbox.transition_payload(transition))
      end)

    state = %{
      state
      | version: state.version + 1,
        cards: Map.put(state.cards, card_key, card)
    }

    broadcast(state)
    state
  end

  defp apply_lifecycle_transition(state, _result), do: state

  defp record_resolution_transition(state, event) do
    case correlated_lifecycle_card(state, event) do
      card when is_map(card) ->
        AttentionInbox.record_card(card, event.action,
          event_id: event.id,
          occurred_at: event.inserted_at
        )

      _card ->
        {:ok, :unmatched}
    end
  end

  defp correlated_lifecycle_card(state, %Event{} = event) do
    with true <- AttentionInbox.lifecycle_action?(event.action),
         {:ok, correlation} <- lifecycle_correlation(event) do
      case Enum.filter(
             Map.values(state.cards),
             &lifecycle_card_match?(&1, event.workspace_id, correlation)
           ) do
        [card] -> card
        _missing_or_ambiguous -> nil
      end
    else
      _result -> nil
    end
  end

  defp lifecycle_correlation(%Event{action: "run." <> _action, target_type: "run"} = event) do
    case meta(event, "run_id") || meta(event, "session_id") || event.target_ref do
      session_id when is_binary(session_id) -> {:ok, {:run, session_id}}
      _session_id -> :error
    end
  end

  defp lifecycle_correlation(%Event{action: action, target_type: "tmux_pane"} = event)
       when action in ["agent.blocked", "agent.state_changed"] do
    tmux_session = meta(event, "tmux_session") || meta(event, "session")
    pane = meta(event, "pane") || event.target_ref

    case {tmux_session, pane} do
      {tmux_session, pane} when is_binary(tmux_session) and is_binary(pane) ->
        {:ok, {:tmux_pane, tmux_session, pane}}

      _missing_exact_target ->
        :error
    end
  end

  defp lifecycle_correlation(%Event{action: action, target_type: target_type} = event)
       when action in ["proposal.applied", "proposal.apply_failed"] and
              target_type in ["run", "command_run"] do
    case meta(event, "run_id") || meta(event, "session_id") do
      session_id when is_binary(session_id) -> {:ok, {:run, session_id}}
      _session_id -> :error
    end
  end

  defp lifecycle_correlation(_event), do: :error

  defp lifecycle_card_match?(card, workspace_id, {:run, session_id}) do
    card.workspace_id == workspace_id and card.session_id == session_id
  end

  defp lifecycle_card_match?(card, workspace_id, {:tmux_pane, tmux_session, pane}) do
    locator = Map.get(card.context, :locator) || Map.get(card.context, "locator") || %{}

    card_tmux_session =
      Map.get(locator, :tmux_session) || Map.get(locator, "tmux_session")

    card_pane = Map.get(locator, :pane) || Map.get(locator, "pane")

    card.workspace_id == workspace_id and
      card_tmux_session == tmux_session and card_pane == pane
  end

  defp event_transition_opts(%Event{action: "agent.state_changed"} = event) do
    case meta(event, "to") |> normalize_event_state() do
      "blocked" -> [state: "needs_attention", phase: "waiting", reason_code: "human_blocked"]
      "working" -> [state: "working", phase: "executing", reason_code: "working"]
      _state -> []
    end
  end

  defp event_transition_opts(_event), do: []

  defp normalize_event_state(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_event_state(value) when is_binary(value), do: String.downcase(value)
  defp normalize_event_state(_value), do: nil

  defp expired?(%{expires_at: %DateTime{} = expires_at}) do
    DateTime.compare(expires_at, now()) == :lt
  end

  defp expired?(_card), do: false

  defp latest_datetime(%DateTime{} = current, %DateTime{} = candidate) do
    if DateTime.compare(candidate, current) == :gt, do: candidate, else: current
  end

  defp latest_datetime(%DateTime{} = current, _candidate), do: current
  defp latest_datetime(_current, %DateTime{} = candidate), do: candidate
  defp latest_datetime(_current, _candidate), do: now()

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
