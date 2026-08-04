defmodule DevIDE.Mobile.Actions do
  @moduledoc """
  Server-authoritative dispatcher for mobile card actions.

  A mobile client submits `%{"card_id", "action", "payload", "request_id"}`. This
  module owns the full trust boundary, in order:

    1. **Reload** the authoritative card server-side from `UserObserver` — the
       client-provided card/resource/workspace ids are never trusted.
    2. **Validate** the requested action against the card-declared action specs
       and validate params deterministically (`DevIDE.Mobile.Card`).
    3. **Authorize** the actor against the *reloaded* card's resource on every
       action, including pairing scope and workspace ownership.
    4. **Persist + idempotency**: write a durable `ActionOutcome` keyed by
       `request_id`; a retried submission replays the recorded outcome, and a
       second device racing on the same card is rejected as already resolved.
    5. **Apply + audit**: run the side effect (via `Runs.Ledger`) and stamp mobile
       audit metadata (source, card, action, device link, platform) atomically
       with the outcome record.

  Returns `{:ok, summary}` or `{:error, reason}`; the channel renders the reply.
  """

  import Ecto.Query, only: [from: 2]

  alias DevIDE.Mobile.{ActionOutcome, AgentInstructions, Card, UserObserver}
  alias DevIde.Repo
  alias DevIDE.Runs.Ledger
  alias DevIDE.Workspaces

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

    # Early idempotency check: a retried submission (e.g. the client never saw the
    # first reply) replays the recorded outcome even though the card may already
    # have been cleared from the transient observer. Scoped to the authenticated
    # user, and only successes replay — a recorded rejection is audit-only and
    # must never block (or be readable by) another attempt.
    case fetch_success_outcome(context.user_id, request_id) do
      %ActionOutcome{} = existing -> replay_existing(existing)
      nil -> dispatch_new(context, params, card_id, action_id, request_id)
    end
  end

  def dispatch(_context, _params), do: {:error, :invalid_payload}

  defp dispatch_new(context, params, card_id, action_id, request_id) do
    action_params = Map.get(params, "payload") || Map.get(params, "params") || %{}

    with {:ok, card} <- reload_card(context.user_id, card_id),
         {:ok, spec} <- Card.fetch_action(card, action_id),
         :ok <- ensure_dispatchable(card),
         {:ok, validated} <- validate_params(spec, action_params),
         :ok <- authorize(context, card) do
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

  # All v1 actions mutate a run and therefore require a session.
  defp ensure_dispatchable(%{session_id: session_id})
       when is_binary(session_id) and session_id != "",
       do: :ok

  defp ensure_dispatchable(_card), do: {:error, :invalid_card}

  # --- Step 2: validation --------------------------------------------------

  defp validate_params(spec, params) do
    case Card.validate_action_params(spec, params) do
      {:ok, validated} -> {:ok, validated}
      {:error, {:required, :note}} -> {:error, :note_required}
      {:error, {:too_long, :note}} -> {:error, :note_too_long}
      {:error, {:required, _field}} -> {:error, :missing_required_input}
      {:error, {:too_long, _field}} -> {:error, :input_too_long}
      {:error, _other} -> {:error, :invalid_payload}
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

  # --- Steps 4 + 5: persist, apply, audit (atomic on the outcome) ---------

  defp commit(context, card, spec, validated, request_id) do
    cond do
      Card.navigation_action?(spec) ->
        commit_navigation(context, card, spec, request_id)

      Card.instruction_action?(spec) ->
        commit_instruction(context, card, spec, validated, request_id)

      true ->
        commit_mutation(context, card, spec, validated, request_id)
    end
  end

  # Instruction action: paste the *server-authored* prompt into the workspace's
  # agent pane. The client submits only the action id and an optional note, so a
  # phone can never dictate arbitrary text through a card — free text goes
  # through the channel's `agent_instruction` event instead, which is gated the
  # same way. No card lock: the failure card stays until the run state changes.
  defp commit_instruction(context, card, spec, validated, request_id) do
    text = instruction_text(spec, validated)

    case AgentInstructions.send(context, %{
           "workspace_id" => card.workspace_id,
           "text" => text
         }) do
      {:ok, summary} ->
        outcome_attrs = %{
          request_id: request_id,
          user_id: context.user_id,
          card_id: card.id,
          action_id: spec.id,
          resource_type: resource_field(card, :type),
          resource_id: resource_field(card, :id),
          device_link_id: Map.get(context, :device_link_id),
          platform: Map.get(context, :platform),
          status: "instructed",
          result: %{
            "tmux_session" => summary.tmux_session,
            "pane_id" => summary.pane_id,
            "submitted" => summary.submitted
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
            if constraint_violation?(
                 changeset,
                 :mobile_action_outcomes_user_request_active_index
               ),
               do: replay(context.user_id, request_id),
               else: {:error, :conflict}
        end

      {:error, reason} ->
        record_rejection(context, card.id, spec.id, request_id, reason)
        {:error, reason}
    end
  end

  defp instruction_text(spec, validated) do
    case Map.get(validated, :note) do
      note when is_binary(note) and note != "" -> spec.instruction <> "\n\n" <> note
      _ -> spec.instruction
    end
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
          do: replay(context.user_id, request_id),
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
        handle_conflict(changeset, context.user_id, request_id)

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
    |> Map.merge(deliver_requested_changes(context, card, action_id, note))
  end

  # "Request changes" and "Deny" emit the same denial event; the difference is
  # what the agent is told. Deny is a full stop. Request changes hands the note
  # to the agent so it can act on it — otherwise the words only ever reach the
  # audit log, and the button promises something the product doesn't do.
  #
  # Delivery is deliberately BEST EFFORT and happens after the decision is
  # already recorded: the denial is authoritative, and a workspace whose agent
  # pane has already exited (common — the run just got blocked) must not turn a
  # valid decision into an error. The outcome records whether the note landed so
  # the phone can say so.
  defp deliver_requested_changes(context, card, "request_changes", note)
       when is_binary(note) and note != "" do
    case AgentInstructions.send(context, %{
           "workspace_id" => card.workspace_id,
           "text" => requested_changes_prompt(card, note)
         }) do
      {:ok, summary} ->
        %{"note_delivered" => true, "note_target" => summary.pane_id}

      {:error, reason} ->
        %{"note_delivered" => false, "note_undelivered_reason" => to_string(reason)}
    end
  end

  defp deliver_requested_changes(_context, _card, _action_id, _note), do: %{}

  # Server-authored framing plus the user's note, the same split the card-level
  # instruction actions use: the phone supplies words, not the whole prompt.
  defp requested_changes_prompt(card, note) do
    subject =
      case meta_value(card, :command_id) do
        command when is_binary(command) and command != "" -> "`#{command}`"
        _ -> "the run awaiting review"
      end

    "Changes requested from mobile on #{subject}. It was not approved.\n\n#{note}"
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

  defp handle_conflict(changeset, user_id, request_id) do
    if constraint_violation?(changeset, :mobile_action_outcomes_accepted_card_id_index) do
      {:error, :card_already_resolved}
    else
      replay(user_id, request_id)
    end
  end

  defp replay(user_id, request_id) do
    case fetch_success_outcome(user_id, request_id) do
      %ActionOutcome{} = outcome -> replay_existing(outcome)
      nil -> {:error, :conflict}
    end
  end

  # Only terminal SUCCESS outcomes (accepted/navigated) for this user replay.
  # Rejections are excluded here (and by the partial index) so they can neither
  # block nor be read by a later attempt.
  defp fetch_success_outcome(user_id, request_id) do
    Repo.one(
      from(o in ActionOutcome,
        where: o.user_id == ^user_id and o.request_id == ^request_id and o.status != "rejected"
      )
    )
  end

  defp replay_existing(%ActionOutcome{status: status} = outcome)
       when status in ["accepted", "navigated", "instructed"] do
    {:ok,
     %{
       status: "accepted",
       action_id: outcome.action_id,
       card_id: outcome.card_id,
       result: outcome.result || %{},
       idempotent: true
     }}
  end

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
