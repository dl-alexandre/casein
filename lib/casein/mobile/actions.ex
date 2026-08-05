defmodule Casein.Mobile.Actions do
  @moduledoc """
  Server-authoritative dispatcher for mobile card actions.

  A mobile client submits `%{"card_id", "action", "payload", "request_id"}`. This
  module owns the full trust boundary, in order:

    1. **Reload** the authoritative card server-side from `UserObserver` — the
       client-provided card/resource/workspace ids are never trusted.
    2. **Validate** the requested action against the card-declared action specs
       and validate params deterministically (`Casein.Mobile.Card`).
    3. **Authorize** the actor against the *reloaded* card's resource on every
       action, including pairing scope and workspace ownership.
    4. **Revalidate runtime target**: intervention actions verify the exact
       current role-marked pane without capturing terminal content.
    5. **Persist + idempotency**: write a durable `ActionOutcome` keyed by
       `request_id`; a retried submission replays the recorded outcome, and a
       second device racing on the same card is rejected as already resolved.
    6. **Apply + audit**: run the side effect (via `Runs.Ledger`) and stamp mobile
       audit metadata (source, card, action, device link, platform) atomically
       with the outcome record.

  Returns `{:ok, summary}` or `{:error, reason}`; the channel renders the reply.
  """

  import Ecto.Query, only: [from: 2]

  alias Casein.Audit
  alias Casein.Mobile.{ActionOutcome, Card, Clarification, Intervention, UserObserver}
  alias Casein.Repo
  alias Casein.Runs.Ledger
  alias Casein.Workspaces

  @type context :: %{
          required(:user_id) => String.t(),
          required(:user) => map(),
          optional(:pairing_workspace_id) => String.t() | nil,
          optional(:device_link_id) => String.t() | nil,
          optional(:platform) => String.t() | nil
        }

  @type summary :: %{
          status: String.t(),
          action_id: String.t(),
          card_id: String.t(),
          result: map(),
          idempotent: boolean()
        }

  @doc """
  Dispatches a `card_action` payload for the given actor context.
  """
  @spec dispatch(context(), map()) :: {:ok, summary()} | {:error, atom()}
  def dispatch(context, %{"card_id" => card_id, "action" => action_id} = params)
      when is_binary(card_id) and is_binary(action_id) do
    request_id = request_id(params, context, card_id, action_id)

    # Origin validation precedes replay. A client that tampers with the active
    # origin must not turn a guessed request id into an apparent accepted action,
    # even though replay itself would not repeat the side effect.
    case ensure_request_origin(context, params, action_id) do
      :ok ->
        # Early idempotency check: a retried submission (e.g. the client never saw
        # the first reply) replays the recorded outcome even though the card may
        # already have been cleared from the transient observer. Scoped to the
        # authenticated user, and only successes replay — a recorded rejection is
        # audit-only and must never block (or be readable by) another attempt.
        case fetch_active_outcome(context.user_id, request_id) do
          %ActionOutcome{} = existing ->
            replay_existing_request(existing, card_id, action_id)

          nil ->
            dispatch_new(context, params, card_id, action_id, request_id)
        end

      {:error, reason} ->
        record_rejection(context, card_id, action_id, request_id, reason)
        {:error, reason}
    end
  end

  def dispatch(_context, _params), do: {:error, :invalid_payload}

  defp dispatch_new(context, params, card_id, action_id, request_id) do
    action_params = Map.get(params, "payload") || Map.get(params, "params") || %{}

    with {:ok, card} <- reload_card(context.user_id, card_id),
         {:ok, spec} <- fetch_declared_action(card, action_id),
         :ok <- ensure_origin(context, params, spec),
         :ok <- ensure_dispatchable(card),
         :ok <- ensure_action_revision(spec, action_params),
         {:ok, validated} <- validate_params(spec, action_params),
         :ok <- authorize(context, card),
         :ok <- validate_runtime_target(card, spec) do
      commit(context, card, spec, validated, request_id)
    else
      {:error, reason} ->
        record_rejection(context, card_id, action_id, request_id, reason)
        {:error, reason}
    end
  end

  # --- Step 1: authoritative reload ---------------------------------------

  defp reload_card(user_id, card_id) do
    user_id
    |> UserObserver.snapshot()
    |> Map.fetch!(:cards)
    |> Enum.find(&(&1.id == card_id))
    |> case do
      nil -> {:error, :card_not_found}
      card -> {:ok, card}
    end
  end

  defp fetch_declared_action(card, action_id) do
    case Card.fetch_action(card, action_id) do
      {:ok, spec} -> {:ok, spec}
      {:error, :unsupported_action} -> Intervention.available_action(card, action_id)
    end
  end

  defp ensure_origin(context, params, _spec), do: ensure_exact_origin(context, params)

  defp ensure_request_origin(context, params, _action_id),
    do: ensure_exact_origin(context, params)

  defp ensure_exact_origin(context, params) do
    trusted_origin_id = Map.get(context, :origin_id)

    case Map.get(params, "origin_id") do
      ^trusted_origin_id when is_binary(trusted_origin_id) and trusted_origin_id != "" -> :ok
      _ -> {:error, :origin_mismatch}
    end
  end

  defp ensure_action_revision(spec, params) do
    if Intervention.requires_revision?(spec) do
      expected_revision = Map.get(spec, :revision)

      case Map.get(params, "revision") do
        ^expected_revision when is_binary(expected_revision) -> :ok
        _ -> {:error, :action_revision_stale}
      end
    else
      :ok
    end
  end

  # All v1 actions mutate a run and therefore require a session.
  defp ensure_dispatchable(%{session_id: session_id})
       when is_binary(session_id) and session_id != "",
       do: :ok

  defp ensure_dispatchable(_card), do: {:error, :invalid_card}

  # --- Step 2: validation --------------------------------------------------

  defp validate_params(spec, params) do
    case Card.validate_action_params(spec, params) do
      {:ok, %{message: message} = validated} when spec.id == "follow_up" ->
        case Intervention.validate_message(message) do
          {:ok, message} -> {:ok, %{validated | message: message}}
          {:error, reason} -> {:error, reason}
        end

      {:ok, validated} ->
        {:ok, validated}

      {:error, {:required, :note}} ->
        {:error, :note_required}

      {:error, {:too_long, :note}} ->
        {:error, :note_too_long}

      {:error, {:required, :message}} ->
        {:error, :message_required}

      {:error, {:too_long, :message}} ->
        {:error, :message_too_long}

      {:error, {:required, _field}} ->
        {:error, :missing_required_input}

      {:error, {:too_long, _field}} ->
        {:error, :input_too_long}

      {:error, _other} ->
        {:error, :invalid_payload}
    end
  end

  # --- Step 3: authorization (against the reloaded card's resource) --------

  defp authorize(context, card) do
    workspace_id = card.workspace_id

    if scoped_to_workspace?(context, workspace_id) do
      authorize_workspace_ownership(context, workspace_id)
    else
      {:error, :workspace_scope_mismatch}
    end
  end

  defp authorize_workspace_ownership(context, workspace_id) do
    case Workspaces.get(workspace_id) do
      {:ok, workspace} ->
        if Workspaces.viewer_terminal_owner?(workspace, context.user),
          do: :ok,
          else: {:error, :unauthorized}

      {:error, :not_found} ->
        {:error, :workspace_not_found}

      {:error, _reason} ->
        {:error, :workspace_unavailable}
    end
  end

  defp scoped_to_workspace?(context, workspace_id) do
    case Map.get(context, :pairing_workspace_id) do
      nil -> true
      ^workspace_id -> true
      _other -> false
    end
  end

  defp validate_runtime_target(card, spec) do
    if Intervention.delivery_action?(spec),
      do: Intervention.validate_action_target(card),
      else: :ok
  end

  # --- Steps 5 + 6: persist, apply, audit (atomic on the outcome) ---------

  defp commit(context, card, spec, validated, request_id) do
    cond do
      Intervention.delivery_action?(spec) ->
        commit_intervention(context, card, spec, validated, request_id)

      Card.navigation_action?(spec) ->
        commit_navigation(context, card, spec, request_id)

      true ->
        commit_mutation(context, card, spec, validated, request_id)
    end
  end

  # An irreversible tmux paste cannot live inside a database transaction. Claim
  # the request first, then deliver at most once. A crash after delivery leaves a
  # processing claim, which fails closed instead of risking a duplicate paste.
  defp commit_intervention(context, card, spec, validated, request_id) do
    outcome_attrs = %{
      request_id: request_id,
      user_id: context.user_id,
      card_id: card.id,
      # Keep the canonical follow-up family id so the existing partial unique
      # index guarantees at-most-one agent delivery for a card across free-text
      # and typed intents.
      action_id: "follow_up",
      resource_type: resource_field(card, :type),
      resource_id: resource_field(card, :id),
      device_link_id: Map.get(context, :device_link_id),
      platform: Map.get(context, :platform),
      status: "processing",
      result: %{"requested_action_id" => spec.id}
    }

    case %ActionOutcome{} |> ActionOutcome.changeset(outcome_attrs) |> Repo.insert() do
      {:ok, outcome} ->
        deliver_intervention(context, card, outcome, spec, validated)

      {:error, changeset} ->
        handle_conflict(changeset, context.user_id, request_id, card.id, spec.id)
    end
  end

  defp deliver_intervention(context, card, outcome, spec, validated) do
    case Intervention.deliver(card, spec, validated) do
      {:ok, result} ->
        case maybe_resolve_clarification(context, card, spec) do
          :ok ->
            accept_delivered_intervention(context, card, outcome, spec, result, "resolved")

          {:error, reason} ->
            # Delivery to tmux is irreversible. Once it succeeds, never mark
            # the claim retryable merely because the secondary durable
            # resolution append failed: a retry could paste the same decision
            # twice. Keep the accepted idempotency/card lock and expose only a
            # bounded resolution marker for reconciliation/diagnosis.
            accept_delivered_intervention(context, card, outcome, spec, result, "failed", reason)
        end

      {:error, reason} ->
        fail_intervention_outcome(outcome, context, card, spec.id, reason)
    end
  end

  defp accept_delivered_intervention(
         context,
         card,
         outcome,
         spec,
         result,
         request_resolution,
         resolution_reason \\ nil
       ) do
    result =
      result
      |> Map.put("requested_action_id", spec.id)
      |> Map.put("request_resolution", request_resolution)

    {:ok, outcome} =
      outcome
      |> ActionOutcome.changeset(%{status: "accepted", result: result})
      |> Repo.update()

    record_intervention_audit(
      context,
      card,
      spec.id,
      "succeeded",
      resolution_reason
    )

    {:ok,
     %{
       status: "accepted",
       action_id: outcome.action_id,
       card_id: outcome.card_id,
       result: outcome.result,
       idempotent: false
     }}
  end

  defp maybe_resolve_clarification(context, %{type: :clarification} = card, spec) do
    if Intervention.delivery_action?(spec) do
      case resolve_clarification(card, %{actor_id: context.user_id, action_id: spec.id}) do
        {:ok, _event, _status} -> :ok
        {:error, _reason} -> {:error, :clarification_resolution_failed}
      end
    else
      {:error, :clarification_response_required}
    end
  end

  defp maybe_resolve_clarification(_context, _card, _spec), do: :ok

  defp clarification_module do
    Application.get_env(:casein, :mobile_clarification_module, Clarification)
  end

  defp resolve_clarification(card, attrs) do
    clarification_module().resolve(card, attrs)
  rescue
    _error -> {:error, :resolution_unavailable}
  catch
    _kind, _reason -> {:error, :resolution_unavailable}
  end

  defp fail_intervention_outcome(outcome, context, card, action_id, reason) do
    _ =
      outcome
      |> ActionOutcome.changeset(%{status: "failed", reason: to_string(reason)})
      |> Repo.update()

    record_intervention_audit(context, card, action_id, "failed", reason)
    {:error, reason}
  end

  defp record_intervention_audit(context, card, action_id, outcome, reason) do
    Audit.emit!(%{
      action: "mobile.intervention",
      workspace_id: card.workspace_id,
      actor_id: context.user_id,
      target_type: "mobile_card",
      target_ref: card.id,
      metadata:
        %{
          "source" => "mobile",
          "action_id" => action_id,
          "card_id" => card.id,
          "outcome" => outcome,
          "reason" => reason && to_string(reason),
          "target_role" => "agent",
          "device_link_id" => Map.get(context, :device_link_id),
          "platform" => Map.get(context, :platform),
          "origin_id" => Map.get(context, :origin_id)
        }
        |> drop_nil_values()
    })
  end

  # Route-only action: record the intent for audit, no runtime mutation and no
  # card lock (the idle card persists until workspace state changes).
  defp commit_navigation(context, card, spec, request_id) do
    outcome_attrs = %{
      request_id: request_id,
      user_id: context.user_id,
      card_id: card.id,
      action_id: spec.id,
      resource_type: resource_field(card, :type),
      resource_id: resource_field(card, :id),
      device_link_id: Map.get(context, :device_link_id),
      platform: Map.get(context, :platform),
      status: "navigated",
      result: %{
        "target" => "session_detail",
        "workspace_id" => card.workspace_id,
        "session_id" => card.session_id
      }
    }

    case %ActionOutcome{} |> ActionOutcome.changeset(outcome_attrs) |> Repo.insert() do
      {:ok, outcome} ->
        {:ok,
         %{
           status: "accepted",
           action_id: spec.id,
           card_id: card.id,
           result: outcome.result,
           idempotent: false
         }}

      {:error, changeset} ->
        if constraint_violation?(changeset, :mobile_action_outcomes_user_request_active_index),
          do: replay(context.user_id, request_id, card.id, spec.id),
          else: {:error, :conflict}
    end
  end

  defp commit_mutation(context, card, spec, validated, request_id) do
    action_id = spec.id
    note = Map.get(validated, :note)

    outcome_attrs = %{
      request_id: request_id,
      user_id: context.user_id,
      card_id: card.id,
      action_id: action_id,
      resource_type: resource_field(card, :type),
      resource_id: resource_field(card, :id),
      device_link_id: Map.get(context, :device_link_id),
      platform: Map.get(context, :platform),
      status: "accepted",
      result: %{}
    }

    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:outcome, ActionOutcome.changeset(%ActionOutcome{}, outcome_attrs))
      |> Ecto.Multi.run(:effect, fn _repo, _changes ->
        {:ok, apply_effect(context, card, action_id, note)}
      end)

    case Repo.transaction(multi) do
      {:ok, %{effect: result}} ->
        clear_card(context.user_id, card)

        {:ok,
         %{
           status: "accepted",
           action_id: action_id,
           card_id: card.id,
           result: result,
           idempotent: false
         }}

      {:error, :outcome, changeset, _changes} ->
        handle_conflict(changeset, context.user_id, request_id, card.id, spec.id)

      {:error, :effect, reason, _changes} ->
        {:error, reason}
    end
  end

  defp apply_effect(context, card, action_id, note) do
    attrs =
      %{
        workspace_id: card.workspace_id,
        actor_id: context.user_id,
        run_id: card.session_id,
        command_id: meta_value(card, :command_id),
        metadata: audit_metadata(context, card, action_id, note)
      }
      |> drop_nil_values()

    event =
      case action_id do
        "approve" -> Ledger.approval_granted(attrs)
        _deny_or_request_changes -> Ledger.approval_denied(attrs)
      end

    %{"event_id" => event && event.id, "action" => action_id}
  end

  # Mobile audit metadata (P2-T4). `mobile_action` is retained for backward
  # compatibility with existing consumers; `action_id`/`device_link_id`/`platform`
  # are the normalized additions.
  defp audit_metadata(context, card, action_id, note) do
    %{
      source: "mobile",
      card_id: card.id,
      action_id: action_id,
      mobile_action: action_id,
      approval_id: meta_value(card, :approval_id),
      device_link_id: Map.get(context, :device_link_id),
      platform: Map.get(context, :platform),
      note: note
    }
    |> drop_nil_values()
  end

  defp clear_card(user_id, card) do
    UserObserver.needs_review_changed(user_id, %{
      workspace_id: card.workspace_id,
      session_id: card.session_id,
      review_count: 0
    })
  end

  # --- Idempotency conflict handling --------------------------------------

  defp handle_conflict(changeset, user_id, request_id, card_id, action_id) do
    cond do
      constraint_violation?(changeset, :mobile_action_outcomes_follow_up_card_id_index) ->
        {:error, :card_already_intervened}

      constraint_violation?(changeset, :mobile_action_outcomes_accepted_card_id_index) ->
        {:error, :card_already_resolved}

      true ->
        replay(user_id, request_id, card_id, action_id)
    end
  end

  defp replay(user_id, request_id, card_id, action_id) do
    case fetch_active_outcome(user_id, request_id) do
      %ActionOutcome{} = outcome -> replay_existing_request(outcome, card_id, action_id)
      nil -> {:error, :conflict}
    end
  end

  # Only terminal SUCCESS outcomes (accepted/navigated) for this user replay.
  # Rejections are excluded here (and by the partial index) so they can neither
  # block nor be read by a later attempt.
  defp fetch_active_outcome(user_id, request_id) do
    Repo.one(
      from(o in ActionOutcome,
        where: o.user_id == ^user_id and o.request_id == ^request_id and o.status != "rejected"
      )
    )
  end

  defp replay_existing_request(%ActionOutcome{} = outcome, card_id, action_id) do
    requested_action_id =
      case outcome.result do
        %{"requested_action_id" => requested} when is_binary(requested) -> requested
        _ -> outcome.action_id
      end

    if outcome.card_id == card_id and requested_action_id == action_id do
      replay_existing(outcome)
    else
      {:error, :idempotency_key_reused}
    end
  end

  defp replay_existing(%ActionOutcome{status: status} = outcome)
       when status in ["accepted", "navigated"] do
    {:ok,
     %{
       status: "accepted",
       action_id: outcome.action_id,
       card_id: outcome.card_id,
       result: outcome.result || %{},
       idempotent: true
     }}
  end

  defp replay_existing(%ActionOutcome{status: "processing"}),
    do: {:error, :intervention_in_progress}

  defp replay_existing(%ActionOutcome{status: "failed"}),
    do: {:error, :intervention_failed}

  # Best-effort durable record of a rejected attempt, for audit only. Not keyed
  # for dedupe: rejections never replay and never block a later corrected
  # attempt with the same request_id.
  defp record_rejection(context, card_id, action_id, request_id, reason) do
    attrs = %{
      request_id: request_id,
      user_id: context.user_id,
      card_id: card_id,
      action_id: action_id,
      device_link_id: Map.get(context, :device_link_id),
      platform: Map.get(context, :platform),
      status: "rejected",
      reason: to_string(reason),
      result: %{}
    }

    %ActionOutcome{}
    |> ActionOutcome.changeset(attrs)
    |> Repo.insert()

    :ok
  rescue
    _error -> :ok
  end

  # --- Helpers -------------------------------------------------------------

  defp request_id(params, context, card_id, action_id) do
    case Map.get(params, "request_id") do
      rid when is_binary(rid) and rid != "" ->
        rid

      _ ->
        # No client dedupe key: derive one so the (card, action) pair is
        # naturally idempotent across double taps.
        "#{context.user_id}:#{card_id}:#{action_id}"
    end
  end

  defp constraint_violation?(%Ecto.Changeset{errors: errors}, name) do
    # Ecto stores `constraint_name` as a string on the changeset error.
    target = to_string(name)

    Enum.any?(errors, fn
      {_field, {_msg, opts}} -> to_string(Keyword.get(opts, :constraint_name, "")) == target
      _other -> false
    end)
  end

  defp resource_field(%{resource: resource}, key) when is_map(resource),
    do: Map.get(resource, key)

  defp resource_field(_card, _key), do: nil

  defp meta_value(%{meta: meta}, key) when is_map(meta) do
    Map.get(meta, key) || Map.get(meta, Atom.to_string(key))
  end

  defp meta_value(_card, _key), do: nil

  defp drop_nil_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
