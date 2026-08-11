defmodule Casein.Attention.Salience do
  @moduledoc """
  How much an attention signal matters — computed **once** for every surface.

  This is the generalized ranker formerly private to
  `Casein.Mobile.AttentionInbox`. Surfaces may choose a **threshold** over the
  result; they must not redefine importance.

  ## Output

  Wire-compatible with the mobile inbox projection:

  - `priority` — `"critical" | "high" | "normal" | "low"`
  - `rank` — integer band score (higher = more salient)
  - `reason_code` — stable string for grouping/telemetry
  - `explanation`, `required_decision`, `notify`
  - `signal` — `Casein.Attention.Signal.t()`

  Assertable in pure tests with plain maps — no LiveView, channel, or Repo.

  ## Agent-state kinds (H28)

  Session-path `agent_states` keep report-only vs derived-only distinct:

  - `:blocked` → `:agent_blocked` (report-only human need)
  - `:errored` → `:agent_errored` (report-only failure claim)
  - `:stalled` → `:agent_stalled` (derived-only; liveness quiet + busy look)
  - `:awaiting_input` → `:agent_awaiting` (derived-only; transcript went quiet
    on an assistant turn)

  Never treat observation failure as quiet/idle — that path is not represented
  here; callers must not pass a fabricated quiet fact when liveness is unknown.
  """

  alias Casein.Attention.Signal

  @type priority :: String.t()
  @type t :: %{
          signal: Signal.t(),
          priority: priority(),
          rank: non_neg_integer(),
          reason_code: String.t(),
          explanation: String.t(),
          required_decision: String.t() | nil,
          notify: boolean()
        }

  @doc """
  Compute salience from normalized facts.

  Accepts either:

  - **Card path** keys used by the mobile inbox: `:card_type`, `:status`,
    `:source`, `:reason`, `:resume_state`, `:resume_phase`, `:availability`,
    `:transition_action`, `:transition_state`, `:transition_phase`
  - **Session path** keys: `:agent_states` (list), `:quiet?`, `:lifecycle_status`
    (`:error | :other`)
  """
  @spec compute(map()) :: t()
  def compute(facts) when is_map(facts) do
    cond do
      Map.has_key?(facts, :agent_states) or Map.has_key?(facts, :quiet?) or
          Map.has_key?(facts, :lifecycle_status) ->
        from_session(facts)

      true ->
        from_card(facts)
    end
  end

  @doc "Build facts from a mobile card, resume projection, and optional latest transition."
  @spec facts_from_card(map(), map(), map() | nil) :: map()
  def facts_from_card(card, resume, latest \\ nil)
      when is_map(card) and is_map(resume) do
    %{
      card_type: normalized(Map.get(card, :type) || Map.get(card, "type")),
      status: normalized(Map.get(card, :status) || Map.get(card, "status")),
      source: normalized(nested(card, [:meta, :source])),
      reason: normalized(nested(card, [:meta, :reason])),
      resume_state: normalized(Map.get(resume, :state) || Map.get(resume, "state")),
      resume_phase: normalized(Map.get(resume, :phase) || Map.get(resume, "phase")),
      availability: normalized(Map.get(resume, :availability) || Map.get(resume, "availability")),
      transition_action:
        transition_field(latest, :action) || transition_field(latest, :event_action),
      transition_state: transition_field(latest, :state),
      transition_phase: transition_field(latest, :phase)
    }
  end

  @doc "Build facts from session-directory metadata (windows + lifecycle status)."
  @spec facts_from_session(map()) :: map()
  def facts_from_session(session) when is_map(session) do
    windows =
      case value(session, :windows) do
        windows when is_list(windows) -> windows
        _ -> session |> value(:metadata, %{}) |> value(:windows, []) |> list_or_empty()
      end

    %{
      agent_states: Enum.map(windows, &normalize_agent_state(value(&1, :agent_state))),
      quiet?: Enum.any?(windows, &truthy?(value(&1, :quiet))),
      lifecycle_status: lifecycle_status(session)
    }
  end

  defp from_card(facts) do
    card_type = fact(facts, :card_type)
    status = fact(facts, :status)
    source = fact(facts, :source)
    reason = fact(facts, :reason)
    resume_state = fact(facts, :resume_state)
    resume_phase = fact(facts, :resume_phase)
    availability = fact(facts, :availability)
    transition_action = fact(facts, :transition_action)
    transition_state = fact(facts, :transition_state)
    transition_phase = fact(facts, :transition_phase)

    cond do
      card_type == "clarification" or
        (resume_state == "needs_attention" and resume_phase == "waiting") or
        transition_action == "agent.blocked" or transition_state == "needs_attention" or
        source == "agent.blocked" or String.contains?(reason, "blocked") ->
        band(
          :agent_blocked,
          "critical",
          700,
          "human_blocked",
          "Agent is blocked on you",
          "Respond",
          true
        )

      transition_action == "run.approval_requested" or
          (resume_state == "needs_attention" and resume_phase == "review") ->
        band(
          :approval_pending,
          "critical",
          680,
          "review_requested",
          "A review decision is waiting",
          "Review",
          true
        )

      transition_action == "deploy.failed" or
          (resume_phase == "deploying" and status in ~w(failed error)) ->
        band(
          :deploy_failed,
          "high",
          580,
          "deployment_failed",
          "Deployment reported a failure",
          "Inspect deployment",
          true
        )

      transition_action in ~w(run.failed run.timed_out gate.failed proposal.apply_failed) or
        transition_state == "failed" or resume_state == "failed" or
          status in ~w(failed timed_out timeout error) ->
        signal =
          case transition_action do
            "gate.failed" -> :checks_failed
            "proposal.apply_failed" -> :apply_failed
            _ -> :run_failed
          end

        band(
          signal,
          "high",
          560,
          if(transition_action == "gate.failed", do: "checks_failed", else: "failure"),
          if(transition_action == "gate.failed",
            do: "Required checks reported a failure",
            else: "Work ended with a reported failure"
          ),
          if(transition_action == "gate.failed", do: "Inspect checks", else: "Inspect failure"),
          true
        )

      transition_action == "deploy.succeeded" or
          (resume_phase == "deploying" and resume_state == "completed") ->
        band(
          :deploy_succeeded,
          "normal",
          430,
          "deployment_completed",
          "Deployment reported completion",
          "Review outcome",
          true
        )

      transition_state in ~w(ready_to_review completed) or
          resume_state in ~w(ready_to_review completed) ->
        band(
          :run_completed,
          "normal",
          400,
          "completed_ready",
          "Work is ready for your review",
          "Review outcome",
          true
        )

      # Match AttentionInbox: only "live" continues; nil/empty/other → offline.
      Map.has_key?(facts, :availability) and availability != "live" ->
        band(
          :offline_resumable,
          "low",
          180,
          "offline_resumable",
          "Last-known context is offline",
          nil,
          false
        )

      transition_state == "working" or transition_phase in ~w(executing testing deploying) or
          resume_state == "working" ->
        band(:working, "low", 120, "working", "Work is still in progress", nil, false)

      true ->
        band(
          :informational,
          "low",
          80,
          "informational",
          "No immediate decision is required",
          nil,
          false
        )
    end
  end

  defp from_session(facts) do
    states = List.wrap(Map.get(facts, :agent_states, []))
    quiet? = Map.get(facts, :quiet?) == true
    lifecycle = Map.get(facts, :lifecycle_status, :other)

    cond do
      # Report-only human need outranks every other session fact.
      :blocked in states ->
        band(
          :agent_blocked,
          "critical",
          700,
          "human_blocked",
          "Agent is blocked on you",
          "Respond",
          true
        )

      # Report-only error claim — not the same kind as blocked or stalled.
      :errored in states ->
        band(
          :agent_errored,
          "high",
          650,
          "agent_errored",
          "Agent reported an error",
          "Inspect failure",
          true
        )

      lifecycle == :error ->
        band(
          :run_failed,
          "high",
          560,
          "failure",
          "Work ended with a reported failure",
          "Inspect failure",
          true
        )

      # Derived-only: the agent's transcript shows it stopped talking. Ranks
      # above :stalled — "it will not move until you act" is a stronger claim
      # than "it looks busy and I see no work" — and below the report-only
      # bands, because conversation shape cannot tell a question from a
      # finished turn. Not a phone interrupt while it is this new (H28).
      :awaiting_input in states ->
        band(
          :agent_awaiting,
          "high",
          520,
          "agent_awaiting",
          "Agent stopped and is waiting on you",
          "Respond",
          true
        )

      # Derived-only: looks busy, worktree quiet. Cockpit-visible; not a phone interrupt.
      :stalled in states ->
        band(
          :agent_stalled,
          "normal",
          450,
          "agent_stalled",
          "Agent looks busy but its worktree is quiet",
          nil,
          false
        )

      :done in states ->
        band(
          :run_completed,
          "normal",
          400,
          "completed_ready",
          "Work is ready for your review",
          "Review outcome",
          true
        )

      quiet? ->
        # #696: session-picker reason :idle — agent went quiet, you are needed.
        # notify stays true for drawer/chrome eligibility; push is a separate
        # Delivery decision and excludes :idle (H28).
        band(
          :idle,
          "normal",
          400,
          "idle",
          "Agent went quiet and may need you",
          nil,
          true
        )

      :working in states ->
        band(:working, "low", 120, "working", "Work is still in progress", nil, false)

      true ->
        band(
          :informational,
          "low",
          80,
          "informational",
          "No immediate decision is required",
          nil,
          false
        )
    end
  end

  defp band(signal, priority, rank, reason_code, explanation, required_decision, notify) do
    %{
      signal: signal,
      priority: priority,
      rank: rank,
      reason_code: reason_code,
      explanation: explanation,
      required_decision: required_decision,
      notify: notify
    }
  end

  defp fact(map, key) do
    map
    |> Map.get(key)
    |> normalized()
  end

  defp normalized(nil), do: ""
  defp normalized(value) when is_atom(value), do: value |> Atom.to_string() |> normalized()
  defp normalized(value), do: value |> to_string() |> String.trim() |> String.downcase()

  defp transition_field(nil, _key), do: nil

  defp transition_field(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, Atom.to_string(key)) do
      nil -> nil
      value -> normalized(value)
    end
  end

  defp nested(map, keys) do
    Enum.reduce_while(keys, map, fn key, current ->
      case current do
        %{} = m ->
          next = Map.get(m, key) || Map.get(m, Atom.to_string(key))
          if is_nil(next), do: {:halt, nil}, else: {:cont, next}

        _ ->
          {:halt, nil}
      end
    end)
  end

  defp value(map, key, default \\ nil) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key), default)
    end
  end

  defp list_or_empty(value) when is_list(value), do: value
  defp list_or_empty(_value), do: []

  defp truthy?(value) when value in [true, 1, "1", "true", "yes", "on"], do: true
  defp truthy?(_value), do: false

  defp lifecycle_status(session) do
    case value(session, :status) do
      status when status in [:error, "error", :failed, "failed"] -> :error
      _ -> :other
    end
  end

  # Keep kinds distinct. "attention" is a legacy picker synonym for blocked need.
  # :unknown is never a quiet/idle fact — drop it as :other so it cannot promote.
  defp normalize_agent_state(state) when state in [:blocked, "blocked", :attention, "attention"],
    do: :blocked

  defp normalize_agent_state(state) when state in [:errored, "errored"], do: :errored

  defp normalize_agent_state(state) when state in [:stalled, "stalled"], do: :stalled

  defp normalize_agent_state(state) when state in [:awaiting_input, "awaiting_input"],
    do: :awaiting_input

  defp normalize_agent_state(state) when state in [:done, "done", :completed, "completed"],
    do: :done

  defp normalize_agent_state(state) when state in [:working, "working", :running, "running"],
    do: :working

  defp normalize_agent_state(_state), do: :other
end
