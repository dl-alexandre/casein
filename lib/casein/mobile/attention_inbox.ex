defmodule Casein.Mobile.AttentionInbox do
  @moduledoc """
  Bounded lifecycle projection and durable meaningful-transition read markers
  for the mobile companion.

  **Ranking / salience** live in `Casein.Attention.Salience` (one shared
  definition for every surface). This module is a mobile envelope over that
  model plus lifecycle history and cursors — not a second ranker and not a task
  database. It never authorizes domain mutations.
  """

  import Ecto.Query

  alias Casein.Attention.{Salience, Signal}
  alias Casein.Attention.Acknowledgement
  alias Casein.Mobile.{AttentionCursor, AttentionTransition, ResumeCard}
  alias Casein.Origin
  alias Casein.Repo

  @version 1
  @transition_limit 12
  @summary_limit 5
  @card_limit 100
  @retained_per_card 50
  @retained_per_origin 2_000
  @meaningful_actions Signal.meaningful_actions()
  @event_labels %{
    "run.started" => "Work started",
    "run.approval_requested" => "Decision requested",
    "run.approval_granted" => "Review approved",
    "run.approval_denied" => "Review denied",
    "run.succeeded" => "Work completed",
    "run.failed" => "Work failed",
    "run.timed_out" => "Work timed out",
    "agent.blocked" => "Agent needs attention",
    "agent.state_changed" => "Agent state changed",
    "gate.passed" => "Checks passed",
    "gate.failed" => "Checks failed",
    "proposal.applied" => "Changes applied",
    "proposal.apply_failed" => "Changes could not be applied",
    "deploy.started" => "Deployment started",
    "deploy.succeeded" => "Deployment completed",
    "deploy.failed" => "Deployment failed"
  }

  @doc "True only for audited lifecycle facts accepted by the inbox projection."
  def lifecycle_action?(action) when is_binary(action), do: action in @meaningful_actions
  def lifecycle_action?(_action), do: false

  @doc "Record a card transition only when its semantic fingerprint changed."
  def record_card(card, event_action, opts \\ [])
      when is_map(card) and is_binary(event_action) do
    if store_enabled?(), do: do_record_card(card, event_action, opts), else: {:ok, :disabled}
  end

  @doc """
  Record many card transitions with one latest-marker lookup and one insert.

  #932 constraint: never Nx4 (1 latest SELECT + 1 INSERT + 2 prune DELETEs
  per card) on the live-work write path. `meaningful_change?` is one `IN`
  query over `mobile_attention_transitions_card_marker_index`. Prune is
  `sweep_history/0`, not per insert. `:unknown` is not classified here —
  this module persists fingerprints only.
  """
  def record_cards(entries) when is_list(entries) do
    if store_enabled?() do
      do_record_cards(entries)
    else
      Enum.map(entries, fn _ -> {:ok, :disabled} end)
    end
  end

  defp do_record_card(card, event_action, opts) do
    attrs = prepare_attrs(card, event_action, opts)
    latest = latest_by_card_keys([attrs])

    if meaningful_change?(attrs, latest) do
      insert_one(attrs)
    else
      {:ok, :unchanged}
    end
  end

  defp do_record_cards(entries) do
    maybe_test_delay()

    prepared =
      Enum.map(entries, fn
        {card, action} -> prepare_attrs(card, action, [])
        {card, action, opts} -> prepare_attrs(card, action, opts)
      end)

    latest = latest_by_card_keys(prepared)

    to_insert = Enum.filter(prepared, &meaningful_change?(&1, latest))
    insert_many(to_insert)
  end

  defp prepare_attrs(card, event_action, opts) do
    origin_id = Keyword.get(opts, :origin_id, Origin.id())
    event_id = Keyword.get(opts, :event_id)
    occurred_at = Keyword.get(opts, :occurred_at, card.updated_at || DateTime.utc_now())
    resume = ResumeCard.project(card)
    event_projection = event_projection(event_action, resume)
    reason_code = Keyword.get(opts, :reason_code, event_projection.reason_code)

    %{
      event_id: bounded(event_id),
      user_id: card.user_id,
      origin_id: origin_id,
      card_id: key(card),
      workspace_id: card.workspace_id,
      session_id: card.session_id,
      state: Keyword.get(opts, :state, event_projection.state),
      phase: Keyword.get(opts, :phase, event_projection.phase),
      reason_code: reason_code,
      event_action: normalize_action(event_action),
      occurred_at: occurred_at
    }
  end

  defp insert_one(attrs) do
    %AttentionTransition{}
    |> AttentionTransition.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:error, %Ecto.Changeset{} = changeset} ->
        if duplicate_event?(changeset), do: {:ok, :duplicate}, else: {:error, changeset}

      result ->
        result
    end
  end

  defp insert_many([]), do: []

  defp insert_many(attrs_list) do
    now = DateTime.utc_now()

    rows =
      Enum.map(attrs_list, fn attrs ->
        attrs
        |> Map.put(:inserted_at, usec(now))
        |> Map.update!(:occurred_at, &usec/1)
        |> Map.take([
          :event_id,
          :user_id,
          :origin_id,
          :card_id,
          :workspace_id,
          :session_id,
          :state,
          :phase,
          :reason_code,
          :event_action,
          :occurred_at,
          :inserted_at
        ])
      end)

    {_count, transitions} = Repo.insert_all(AttentionTransition, rows, returning: true)
    Enum.map(transitions, &{:ok, &1})
  end

  @doc """
  Project attention metadata for a bounded card set with two bulk queries.
  """
  def project_many(user_id, origin_id, cards)
      when is_binary(user_id) and is_binary(origin_id) and is_list(cards) do
    if store_enabled?() do
      do_project_many(user_id, origin_id, cards)
    else
      Map.new(cards, &{&1.id, project(&1, [], nil, origin_id)})
    end
  end

  defp do_project_many(user_id, origin_id, cards) do
    cards = Enum.take(cards, @card_limit)
    card_ids = Enum.map(cards, &key/1)

    transitions =
      AttentionTransition
      |> where(
        [t],
        t.user_id == ^user_id and t.origin_id == ^origin_id and t.card_id in ^card_ids
      )
      |> order_by([t], desc: t.id)
      |> Repo.all()
      |> Enum.group_by(& &1.card_id)

    cursors =
      AttentionCursor
      |> where(
        [c],
        c.user_id == ^user_id and c.origin_id == ^origin_id and c.subject_kind == "card" and
          c.card_id in ^card_ids
      )
      |> Repo.all()
      |> Map.new(&{&1.card_id, &1})

    Map.new(cards, fn card ->
      attention_key = key(card)
      retained_history = Map.get(transitions, attention_key, [])
      cursor = Map.get(cursors, attention_key)
      cursor_marker = cursor_value(cursor, :through_transition_id) || 0
      unread_count = Enum.count(retained_history, &((&1.id || 0) > cursor_marker))
      history = Enum.take(retained_history, @transition_limit)

      lifecycle_history =
        retained_history
        |> Enum.sort_by(
          &{datetime_sort_key(transition_value(&1, :occurred_at)),
           transition_value(&1, :id) || 0},
          :desc
        )
        |> Enum.take(@transition_limit)

      {card.id,
       project(card, history, cursor, origin_id,
         unread_count: unread_count,
         history_truncated?: length(retained_history) > length(history),
         lifecycle_transitions: lifecycle_history
       )}
    end)
  end

  @doc "Pure deterministic projection used by server rendering and tests."
  def project(card, transitions \\ [], cursor \\ nil, origin_id \\ Origin.id(), opts \\ [])
      when is_map(card) and is_list(transitions) do
    resume = ResumeCard.project(card)
    through_marker = transitions |> List.first() |> transition_value(:id)
    cursor_marker = cursor_value(cursor, :through_transition_id) || 0

    unread =
      Enum.filter(transitions, fn transition ->
        (transition_value(transition, :id) || 0) > cursor_marker
      end)

    lifecycle_source = Keyword.get(opts, :lifecycle_transitions, transitions)

    lifecycle_transitions =
      case {lifecycle_source, nested(card, [:meta, :attention_transition])} do
        {[], embedded} when is_map(embedded) -> [embedded]
        {history, _embedded} -> history
      end

    lifecycle = lifecycle(Enum.reverse(lifecycle_transitions))
    latest = latest_transition(card, lifecycle)
    ranking = ranking(card, resume, latest)
    unresolved? = Casein.Attention.Delivery.needs_me_pin?(card)
    unread_count = Keyword.get(opts, :unread_count, length(unread))

    %{
      version: @version,
      key: key(card),
      identity: "#{origin_id}:#{key(card)}",
      priority: ranking.priority,
      rank: ranking.rank,
      reason_code: ranking.reason_code,
      explanation: ranking.explanation,
      required_decision: ranking.required_decision,
      # This is deliberately independent of the read cursor. Viewing only
      # acknowledges delivery; an authoritative handled/resolved card state (or
      # removal from the observer) is what releases a Needs Me request.
      # Pin threshold: Casein.Attention.Delivery.needs_me_pin?/1
      unresolved?: unresolved?,
      pin: if(unresolved?, do: "needs_me", else: nil),
      # signal + notify from Salience; push uses Delivery.push_eligible?/1 (needs signal)
      signal: ranking.signal,
      # notify bit from Salience; eligibility floor is Delivery.notify_eligible?/1
      notify: ranking.notify,
      changed_at: transition_value(latest, :occurred_at) || card.updated_at,
      notification_group: "#{origin_id}:#{key(card)}:#{ranking.reason_code}",
      since_viewed: %{
        count: unread_count,
        through_marker: through_marker,
        viewed_through_marker: empty_to_nil(cursor_marker),
        changes: Enum.map(Enum.take(unread, @summary_limit), &transition_summary/1),
        truncated?: unread_count > @summary_limit or Keyword.get(opts, :history_truncated?, false)
      },
      lifecycle: lifecycle,
      completion: completion(card, resume, lifecycle)
    }
  end

  @doc """
  Atomically advance the shared per-user/origin/card SEEN watermark to an exact
  server-issued marker. A lower concurrent marker can never reset it.

  Delegates to `Casein.Attention.Acknowledgement` so phone SEEN settles the
  drawer (and other surfaces) for the same subject.
  """
  def mark_viewed(user_id, origin_id, card_id, marker, opts \\ [])

  def mark_viewed(user_id, origin_id, card_id, marker, opts)
      when is_binary(user_id) and is_binary(origin_id) and is_binary(card_id) and
             is_integer(marker) and marker > 0 do
    Acknowledgement.mark_card_seen_through(user_id, origin_id, card_id, marker, opts)
  end

  def mark_viewed(_user_id, _origin_id, _card_id, _marker, _opts),
    do: {:error, :invalid_attention_marker}

  @doc """
  Stable lifecycle/read key. Typed task identity wins; a session is a scoped
  fallback and remains navigation context rather than a promoted task record.
  """
  def key(card) when is_map(card) do
    resume = ResumeCard.project(card)
    workspace_id = transition_value(card, :workspace_id)

    suffix =
      case resume.task_ref do
        %{type: type, id: id} -> "task:#{type}:#{id}"
        _ -> "session:#{transition_value(card, :session_id) || transition_value(card, :id)}"
      end

    "#{workspace_id}:#{suffix}"
  end

  @doc "Bounded transition shape safe to retain on an in-memory card projection."
  def transition_payload(%AttentionTransition{} = transition), do: transition_summary(transition)
  def transition_payload(transition) when is_map(transition), do: transition_summary(transition)

  @doc """
  Drop overflow history. Periodic sweeper only — never call from `record_card/3`
  or `record_cards/1` (#932). Bounds stay `@retained_per_card` / `@retained_per_origin`.
  """
  def sweep_history do
    card_limit = retained_per_card()
    origin_limit = retained_per_origin()

    card_deleted =
      overflowing_cards(card_limit)
      |> Enum.reduce(0, fn row, acc ->
        acc + prune_card(row.user_id, row.origin_id, row.card_id, card_limit)
      end)

    origin_deleted =
      overflowing_origins(origin_limit)
      |> Enum.reduce(0, fn row, acc ->
        acc + prune_origin(row.user_id, row.origin_id, origin_limit)
      end)

    card_deleted + origin_deleted
  end

  def retained_per_card do
    Application.get_env(:casein, :attention_retained_per_card, @retained_per_card)
  end

  def retained_per_origin do
    Application.get_env(:casein, :attention_retained_per_origin, @retained_per_origin)
  end

  defp latest_by_card_keys([]), do: %{}

  defp latest_by_card_keys(attrs_list) do
    groups = Enum.group_by(attrs_list, &{&1.user_id, &1.origin_id})

    Enum.reduce(groups, %{}, fn {{user_id, origin_id}, group}, acc ->
      card_ids = group |> Enum.map(& &1.card_id) |> Enum.uniq()

      latest_ids =
        from t in AttentionTransition,
          where: t.user_id == ^user_id and t.origin_id == ^origin_id and t.card_id in ^card_ids,
          group_by: t.card_id,
          select: max(t.id)

      AttentionTransition
      |> where([t], t.id in subquery(latest_ids))
      |> Repo.all()
      |> Enum.reduce(acc, fn transition, inner ->
        Map.put(inner, {transition.user_id, transition.origin_id, transition.card_id}, transition)
      end)
    end)
  end

  defp meaningful_change?(attrs, latest) do
    case Map.get(latest, {attrs.user_id, attrs.origin_id, attrs.card_id}) do
      nil ->
        true

      existing ->
        {existing.state, existing.phase, existing.reason_code, existing.event_action} !=
          {attrs.state, attrs.phase, attrs.reason_code, attrs.event_action}
    end
  end

  defp duplicate_event?(changeset) do
    Enum.any?(changeset.errors, fn
      {:event_id, {_message, metadata}} -> metadata[:constraint] == :unique
      _error -> false
    end)
  end

  defp overflowing_cards(limit) do
    from(t in AttentionTransition,
      group_by: [t.user_id, t.origin_id, t.card_id],
      having: count(t.id) > ^limit,
      select: %{user_id: t.user_id, origin_id: t.origin_id, card_id: t.card_id}
    )
    |> Repo.all()
  end

  defp overflowing_origins(limit) do
    from(t in AttentionTransition,
      group_by: [t.user_id, t.origin_id],
      having: count(t.id) > ^limit,
      select: %{user_id: t.user_id, origin_id: t.origin_id}
    )
    |> Repo.all()
  end

  defp prune_card(user_id, origin_id, card_id, limit) do
    keep_ids =
      from t in AttentionTransition,
        where: t.user_id == ^user_id and t.origin_id == ^origin_id and t.card_id == ^card_id,
        order_by: [desc: t.id],
        limit: ^limit,
        select: t.id

    {count, _} =
      from(t in AttentionTransition,
        where:
          t.user_id == ^user_id and t.origin_id == ^origin_id and t.card_id == ^card_id and
            t.id not in subquery(keep_ids)
      )
      |> Repo.delete_all()

    count
  end

  defp prune_origin(user_id, origin_id, limit) do
    keep_ids =
      from t in AttentionTransition,
        where: t.user_id == ^user_id and t.origin_id == ^origin_id,
        order_by: [desc: t.id],
        limit: ^limit,
        select: t.id

    {count, _} =
      from(t in AttentionTransition,
        where:
          t.user_id == ^user_id and t.origin_id == ^origin_id and t.id not in subquery(keep_ids)
      )
      |> Repo.delete_all()

    count
  end

  defp maybe_test_delay do
    case Application.get_env(:casein, :attention_record_delay_ms, 0) do
      n when is_integer(n) and n > 0 -> Process.sleep(n)
      _ -> :ok
    end
  end

  defp ranking(card, resume, latest) do
    card
    |> Salience.facts_from_card(resume, latest)
    |> Salience.compute()
    |> Map.take([
      :signal,
      :priority,
      :rank,
      :reason_code,
      :explanation,
      :required_decision,
      :notify
    ])
  end

  defp reason_code(_card, event_action, resume) do
    action = normalize_action(event_action)

    cond do
      action == "agent.blocked" ->
        "human_blocked"

      action == "run.approval_requested" ->
        "review_requested"

      action in ~w(run.failed run.timed_out gate.failed proposal.apply_failed deploy.failed) ->
        "failure"

      action in ~w(run.succeeded gate.passed proposal.applied deploy.succeeded) ->
        "completed"

      action == "run.started" ->
        "working"

      action in @meaningful_actions ->
        action |> String.replace(".", "_")

      resume.availability != "live" ->
        "offline_resumable"

      resume.state == "needs_attention" ->
        "needs_attention"

      resume.state == "failed" ->
        "failure"

      resume.state == "completed" ->
        "completed"

      true ->
        "working"
    end
  end

  defp event_projection(event_action, resume) do
    case normalize_action(event_action) do
      "run.started" ->
        %{state: "working", phase: "executing", reason_code: "working"}

      "run.approval_requested" ->
        %{state: "needs_attention", phase: "review", reason_code: "review_requested"}

      "run.approval_granted" ->
        %{state: "working", phase: "executing", reason_code: "review_approved"}

      "run.approval_denied" ->
        %{state: "completed", phase: "review", reason_code: "review_denied"}

      action when action in ~w(run.failed run.timed_out) ->
        %{state: "failed", phase: "complete", reason_code: "failure"}

      "run.succeeded" ->
        %{state: "completed", phase: "complete", reason_code: "completed"}

      "agent.blocked" ->
        %{state: "needs_attention", phase: "waiting", reason_code: "human_blocked"}

      "agent.state_changed" ->
        %{state: resume.state, phase: resume.phase, reason_code: "agent_state_changed"}

      "gate.passed" ->
        %{state: "working", phase: "testing", reason_code: "completed"}

      "gate.failed" ->
        %{state: "failed", phase: "testing", reason_code: "failure"}

      "proposal.applied" ->
        %{state: "ready_to_review", phase: "review", reason_code: "completed"}

      "proposal.apply_failed" ->
        %{state: "failed", phase: "review", reason_code: "failure"}

      "deploy.started" ->
        %{state: "working", phase: "deploying", reason_code: "deploy_started"}

      "deploy.succeeded" ->
        %{state: "completed", phase: "deploying", reason_code: "completed"}

      "deploy.failed" ->
        %{state: "failed", phase: "deploying", reason_code: "failure"}

      _action ->
        %{
          state: resume.state,
          phase: resume.phase,
          reason_code: reason_code(%{}, event_action, resume)
        }
    end
  end

  defp lifecycle(transitions) do
    events =
      transitions
      |> Enum.map(&transition_summary/1)
      |> Enum.sort_by(fn event ->
        {datetime_sort_key(event.occurred_at), event.marker || 0}
      end)

    %{
      status: lifecycle_status(events),
      partial?: lifecycle_partial?(events),
      stages: Enum.take(events, -@transition_limit)
    }
  end

  defp lifecycle_status(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value("unknown", fn event ->
      case event.action do
        action when action in ~w(run.failed run.timed_out gate.failed deploy.failed) -> "failed"
        "deploy.succeeded" -> "deployed"
        "deploy.started" -> "deploying"
        "gate.passed" -> "testing"
        "run.succeeded" -> "completed"
        "run.approval_requested" -> "waiting"
        action when action in ~w(run.approval_granted run.approval_denied) -> "review_resolved"
        "agent.blocked" -> "waiting"
        "agent.state_changed" -> lifecycle_state_status(event)
        "run.started" -> "working"
        _action -> nil
      end
    end)
  end

  defp lifecycle_state_status(%{state: "failed"}), do: "failed"
  defp lifecycle_state_status(%{state: "needs_attention"}), do: "waiting"
  defp lifecycle_state_status(%{phase: "deploying"}), do: "deploying"
  defp lifecycle_state_status(%{phase: "testing"}), do: "testing"
  defp lifecycle_state_status(%{state: "completed"}), do: "completed"
  defp lifecycle_state_status(%{state: "working"}), do: "working"
  defp lifecycle_state_status(_event), do: nil

  defp lifecycle_partial?(events) do
    actions = Enum.map(events, & &1.action)
    terminal? = Enum.any?(actions, &(&1 in ~w(run.succeeded run.failed run.timed_out)))
    deploy_terminal? = Enum.any?(actions, &(&1 in ~w(deploy.succeeded deploy.failed)))

    (terminal? and "run.started" not in actions) or
      (deploy_terminal? and "deploy.started" not in actions)
  end

  defp completion(card, resume, lifecycle) do
    terminal? =
      transition_value(card, :type) in [:outcome, "outcome"] and
        resume.state in ~w(failed ready_to_review completed)

    %{
      outcome: if(terminal?, do: resume.state, else: nil),
      verification: bounded_projection(nested(card, [:meta, :verification])) || "not_reported",
      merge_sha: bounded_projection(nested(card, [:meta, :merge_sha])),
      deploy_sha: bounded_projection(nested(card, [:meta, :deploy_sha])),
      unresolved_risks?: nested(card, [:meta, :unresolved_risks]) == true,
      authoritative?: terminal?,
      partial?: lifecycle.partial?
    }
  end

  defp transition_summary(transition) do
    action =
      transition_value(transition, :event_action) || transition_value(transition, :action) ||
        "unknown"

    %{
      marker: transition_value(transition, :id) || transition_value(transition, :marker),
      action: action,
      label: Map.get(@event_labels, action, "Status changed"),
      state: transition_value(transition, :state),
      phase: transition_value(transition, :phase),
      reason_code: transition_value(transition, :reason_code),
      occurred_at: transition_value(transition, :occurred_at)
    }
  end

  defp cursor_value(nil, _key), do: nil
  defp cursor_value(cursor, key), do: transition_value(cursor, key)

  defp transition_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp transition_value(_value, _key), do: nil

  defp nested(map, keys) do
    Enum.reduce_while(keys, map, fn key, current ->
      case transition_value(current, key) do
        nil -> {:halt, nil}
        next -> {:cont, next}
      end
    end)
  end

  defp normalize_action(action) when is_binary(action) do
    if action in @meaningful_actions, do: action, else: String.slice(action, 0, 120)
  end

  defp normalize_action(_action), do: "mobile.card_changed"

  defp bounded(nil), do: nil
  defp bounded(value) when is_binary(value), do: value |> String.trim() |> String.slice(0, 240)
  defp bounded(_value), do: nil

  defp bounded_projection(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> String.slice(text, 0, 240)
    end
  end

  defp bounded_projection(_value), do: nil

  defp latest_transition(card, lifecycle) do
    persisted = List.last(lifecycle.stages)
    embedded = nested(card, [:meta, :attention_transition])

    [persisted, embedded]
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(
      &{datetime_sort_key(transition_value(&1, :occurred_at)),
       transition_value(&1, :marker) || 0},
      fn -> nil end
    )
  end

  defp datetime_sort_key(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)

  defp datetime_sort_key(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _offset} -> DateTime.to_unix(parsed, :microsecond)
      _error -> 0
    end
  end

  defp datetime_sort_key(_value), do: 0

  defp empty_to_nil(0), do: nil
  defp empty_to_nil(value), do: value

  defp usec(%DateTime{microsecond: {_, 6}} = value), do: value

  defp usec(%DateTime{microsecond: {usec, _}} = value) do
    %{value | microsecond: {usec, 6}}
  end

  defp store_enabled? do
    Application.get_env(:casein, :mobile_attention_store_enabled, true) != false
  end
end
