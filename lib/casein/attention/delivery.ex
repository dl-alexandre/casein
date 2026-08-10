defmodule Casein.Attention.Delivery do
  @moduledoc """
  Per-surface **thresholds** over shared salience, plus focus-aware routing.

  Delivery never redefines importance. A surface may choose how high salience
  must be before it shows a badge, pins a row, or pages the operator — it may
  not invent its own ranking.

  ## Inspectable thresholds (one place)

  "Push fires above X, a badge appears above Y" — read this table, not call sites.

  | Surface | Clears when | Constant / helper |
  |---------|-------------|-------------------|
  | OS push (mobile card path) | `notify_eligible?` **and** signal ∈ `@push_signals` | `push_eligible?/1` |
  | Notifications drawer create (mobile) | Salience `notify` ∧ rank ≥ **400** | `drawer_eligible?/1` (= `notify_eligible?/1`) |
  | Mobile inbox `notify` bit / floor | Salience `notify` ∧ rank ≥ **400** | `notify_eligible?/1`, `notify_rank_floor/0` |
  | Session rail `:needs_you` | signal → section via classification | `session_classification/1`, `session_needs_you?/1` |
  | Session rail urgency sort | blocked/errored < stalled < completed < idle | `session_reason_urgency/1` |
  | Quiet chrome badge | unseen > 0 → `"unseen"`, else quiet → `"inline"` | `chrome_attention_label/2` |
  | Needs Me pin | unresolved decision card types | `needs_me_pin?/1` |
  | Drawer severity chrome | priority critical/high → `"warning"` | `drawer_severity/1` |
  | Browser quiet-agent OS notify | focus table + observed_working? | `delivery_decision/1` |

  Rank floor **400** is shared by notify/drawer. Push is a **stricter** cut on
  the same salience (signal allowlist), not the same predicate as the drawer.

  ## Push is not cockpit visibility (H28)

  `push_eligible?/1` answers "should this interrupt a human on their phone."
  `session_needs_you?/1` answers "should this be visible in the cockpit rail."
  `drawer_eligible?/1` answers "should a notifications-drawer row be created."
  They share **one salience definition** and apply **different thresholds**.
  Do not collapse them into one boolean.

  Push includes human blockers, approvals, failures, and completed work that
  already pages today. It deliberately excludes:

  - `:agent_stalled` — derived observation; high cockpit value, low interrupt value
  - `:idle` — quiet-window chrome on the rail; drawer/notify floor may still clear
  - `:working` / `:informational` / `:offline_resumable` — below the floor

  ## Unknown is not quiet

  Delivery never invents a quiet/idle fact. Callers pass `quiet?` only from a
  real quiet observation. An unscannable worktree (`AgentLiveness` `{:error, _}`)
  must not become `quiet?: true` — collapsing unknown into "below threshold"
  reports calm exactly when observation failed.

  ## Focus-aware quiet-agent routing

  `delivery_decision/1` preserves the pre-#697 `Casein.Attention.Policy` table
  for quiet-agent transitions (vocabulary from #696: `delivery_*`, not
  `quiet_*`). `surface_state` is an input here.

  Session-picker membership (`:needs_you` / `:working` / `:recent`) is
  `session_classification/1` — a threshold projection over
  `Casein.Attention.Salience`, not a second ranker.
  """

  alias Casein.Attention.Salience

  @type surface_state :: :focused | :visible | :hidden | :unknown
  @type target_state :: :focused | :visible | :hidden | :unknown
  @type reaction :: :nothing | :inline | :notify
  @type delivery_reason ::
          :cold_ready
          | :focused_target
          | :focused_workspace
          | :background_surface

  @type delivery_decision :: %{
          reaction: reaction(),
          reason: delivery_reason(),
          surface_state: surface_state(),
          target_state: target_state(),
          observed_working?: boolean()
        }

  @type session_section :: :needs_you | :working | :recent
  @type session_reason ::
          :blocked
          | :errored
          | :stalled
          | :error
          | :orphaned_claim
          | :completed
          | :idle
          | :working
          | :recent
  @type session_classification :: %{section: session_section(), reason: session_reason()}

  # ---------------------------------------------------------------------------
  # Thresholds — the only place surfaces may look for "how high is high enough"
  # ---------------------------------------------------------------------------

  # Mobile notify / drawer-create floor (shared band floor with push rank cut).
  # Critical/high/normal actionable outcomes sit at ≥400. Working (120) and
  # informational (80) stay below.
  @notify_rank_floor 400

  # Session rail `:needs_you` includes the same actionable bands plus stalled.
  # Encoded via `session_classification/1` signal map (not a second ranker).
  @session_needs_you_rank_floor 400

  # OS push may interrupt only for these signals. Same salience definition as
  # the cockpit; stricter membership than `session_needs_you?`.
  @push_signals MapSet.new([
                  :agent_blocked,
                  :agent_errored,
                  :approval_pending,
                  :deploy_failed,
                  :run_failed,
                  :checks_failed,
                  :apply_failed,
                  :deploy_succeeded,
                  :run_completed
                ])

  # Within `:needs_you`, lower urgency sorts first.
  # `:orphaned_claim` is fleet-board lease debt (#812) — after hard agent
  # failures, before quiet-idle capacity.
  @session_reason_urgency %{
    blocked: 0,
    errored: 0,
    error: 0,
    stalled: 1,
    orphaned_claim: 2,
    completed: 2,
    idle: 3
  }

  # Priorities that paint the notifications drawer row as warning chrome.
  @drawer_warning_priorities ~w(critical high)

  # Card types that pin Needs Me while not yet handled (lifecycle, not rank).
  @needs_me_card_types ~w(clarification needs_review)
  @needs_me_resolved_statuses ~w(resolved done handled dismissed)

  @doc "Rank floor for mobile notify and drawer create."
  @spec notify_rank_floor() :: non_neg_integer()
  def notify_rank_floor, do: @notify_rank_floor

  @doc "Rank floor documented for session-rail needs_you (see session_classification/1)."
  @spec session_needs_you_rank_floor() :: non_neg_integer()
  def session_needs_you_rank_floor, do: @session_needs_you_rank_floor

  @doc "Signals that may clear the OS-push threshold (inspectable set)."
  @spec push_signals() :: MapSet.t(atom())
  def push_signals, do: @push_signals

  @doc "Normalize browser/workspace surface state from atoms or client strings."
  @spec surface_state(term()) :: surface_state()
  def surface_state(state) when state in [:focused, :visible, :hidden, :unknown], do: state
  def surface_state("focused"), do: :focused
  def surface_state("visible"), do: :visible
  def surface_state("hidden"), do: :hidden
  def surface_state("unknown"), do: :unknown
  def surface_state(_state), do: :unknown

  @doc "Normalize the target's relationship to the current operator surface."
  @spec target_state(term()) :: target_state()
  def target_state(state) when state in [:focused, :visible, :hidden, :unknown], do: state
  def target_state("focused"), do: :focused
  def target_state("visible"), do: :visible
  def target_state("hidden"), do: :hidden
  def target_state("unknown"), do: :unknown
  def target_state(_state), do: :unknown

  @doc """
  Full delivery decision with normalized inputs and a reason for telemetry.

  Names the suppress/inline/notify choice for a quiet-agent transition — not
  the session-picker `:idle` reason (#696).
  """
  @spec delivery_decision(map()) :: delivery_decision()
  def delivery_decision(attrs) when is_map(attrs) do
    surface = surface_state(Map.get(attrs, :surface_state))
    target = target_state(Map.get(attrs, :target_state))
    observed_working? = Map.get(attrs, :observed_working?) == true

    {reaction, reason} =
      cond do
        not observed_working? ->
          {:inline, :cold_ready}

        surface == :focused and target == :focused ->
          {:nothing, :focused_target}

        surface == :focused ->
          {:inline, :focused_workspace}

        true ->
          {:notify, :background_surface}
      end

    %{
      reaction: reaction,
      reason: reason,
      surface_state: surface,
      target_state: target,
      observed_working?: observed_working?
    }
  end

  @doc "Attention reaction for a quiet-agent transition (reaction only)."
  @spec delivery_reaction(map()) :: reaction()
  def delivery_reaction(attrs) when is_map(attrs) do
    attrs
    |> delivery_decision()
    |> Map.fetch!(:reaction)
  end

  @doc "Attention reaction for steady quiet-agent chrome."
  @spec window_delivery(map()) :: reaction()
  def window_delivery(attrs) when is_map(attrs) do
    if Map.get(attrs, :quiet?) == true, do: :inline, else: :nothing
  end

  @doc "JSON-safe reaction label for browser payloads and data attributes."
  @spec reaction_label(reaction()) :: String.t()
  def reaction_label(:nothing), do: "nothing"
  def reaction_label(:inline), do: "inline"
  def reaction_label(:notify), do: "notify"

  @doc """
  Whether shared salience clears the default **notify/drawer** threshold.

  Used by mobile inbox `notify` and notifications-drawer create. This is **not**
  the OS-push gate — use `push_eligible?/1` for phone interrupts.
  """
  @spec notify_eligible?(Salience.t() | map()) :: boolean()
  def notify_eligible?(%{notify: notify, rank: rank})
      when is_boolean(notify) and is_integer(rank) do
    notify and rank >= @notify_rank_floor
  end

  def notify_eligible?(%{notify: notify}) when is_boolean(notify), do: notify
  def notify_eligible?(_), do: false

  @doc """
  OS push (mobile card path) — interrupt the human on their phone.

  Distinct from cockpit visibility (`session_needs_you?/1`) and from the
  drawer/notify floor (`notify_eligible?/1`). Requires:

  1. `notify_eligible?/1` (rank floor + Salience notify bit), and
  2. signal ∈ `push_signals/0` (excludes `:idle` and `:agent_stalled`).
  """
  @spec push_eligible?(Salience.t() | map()) :: boolean()
  def push_eligible?(%{signal: signal} = salience) do
    notify_eligible?(salience) and MapSet.member?(@push_signals, signal)
  end

  def push_eligible?(_), do: false

  @doc """
  Notifications drawer row create from a mobile card.

  Same rank floor as `notify_eligible?/1` — **not** the OS-push gate. Idle
  quiet-window salience can clear the drawer while `push_eligible?/1` is false.
  """
  @spec drawer_eligible?(Salience.t() | map()) :: boolean()
  def drawer_eligible?(salience), do: notify_eligible?(salience)

  @doc """
  Whether a session salience clears the session-rail `:needs_you` section.

  Prefer `session_classification/1` for the full section/reason projection;
  this boolean is the threshold half for tests and greppable docs.
  """
  @spec session_needs_you?(Salience.t() | map()) :: boolean()
  def session_needs_you?(salience) when is_map(salience) do
    session_classification(salience).section == :needs_you
  end

  def session_needs_you?(_), do: false

  @doc """
  Urgency rank for needs-you row ordering: lower sorts first.

  Blocked/errored/error before stalled before completed before idle.
  Unknown reasons sort last.
  """
  @spec session_reason_urgency(session_reason() | term()) :: non_neg_integer()
  def session_reason_urgency(reason) when is_atom(reason) do
    Map.get(@session_reason_urgency, reason, 4)
  end

  def session_reason_urgency(_), do: 4

  @doc """
  Cockpit quiet-chrome attention label for a window or session aggregate.

  - any unseen quiet → `"unseen"` (louder badge)
  - otherwise any quiet → Policy steady chrome (`"inline"` / `"nothing"`)
  """
  @spec chrome_attention_label(non_neg_integer(), non_neg_integer()) :: String.t()
  def chrome_attention_label(unseen_count, quiet_count)
      when is_integer(unseen_count) and is_integer(quiet_count) do
    cond do
      unseen_count > 0 -> "unseen"
      quiet_count > 0 -> reaction_label(window_delivery(%{quiet?: true}))
      true -> reaction_label(window_delivery(%{quiet?: false}))
    end
  end

  @doc "Per-window chrome label from quiet + unseen flags."
  @spec window_chrome_attention(boolean(), boolean()) :: String.t()
  def window_chrome_attention(quiet?, unseen_quiet?)
      when is_boolean(quiet?) and is_boolean(unseen_quiet?) do
    chrome_attention_label(
      if(unseen_quiet?, do: 1, else: 0),
      if(quiet?, do: 1, else: 0)
    )
  end

  @doc """
  Needs Me pin threshold: decision-card types that are not yet handled.

  Lifecycle pin, not a rank cut — viewing alone does not clear it (#698).
  """
  @spec needs_me_pin?(map()) :: boolean()
  def needs_me_pin?(card) when is_map(card) do
    type = normalized(Map.get(card, :type) || Map.get(card, "type"))
    status = normalized(Map.get(card, :status) || Map.get(card, "status"))

    type in @needs_me_card_types and status not in @needs_me_resolved_statuses
  end

  def needs_me_pin?(_), do: false

  @doc "Notifications drawer severity chrome from shared priority string."
  @spec drawer_severity(String.t() | atom() | nil) :: String.t()
  def drawer_severity(priority) when is_atom(priority),
    do: drawer_severity(Atom.to_string(priority))

  def drawer_severity(priority) when is_binary(priority) do
    if String.downcase(priority) in @drawer_warning_priorities, do: "warning", else: "info"
  end

  def drawer_severity(_), do: "info"

  @doc """
  Session-picker classification as a **projection** over salience.

  Preserves today's `SessionDirectory.Attention` membership and #696 reason
  `:idle` (agent went quiet → needs you). H28 keeps report-only `:errored` and
  derived-only `:stalled` as distinct reasons (not collapsed into `:blocked`).
  """
  @spec session_classification(Salience.t() | map()) :: session_classification()
  def session_classification(%{signal: signal} = salience) do
    case signal do
      :agent_blocked ->
        %{section: :needs_you, reason: :blocked}

      :agent_errored ->
        %{section: :needs_you, reason: :errored}

      :agent_stalled ->
        %{section: :needs_you, reason: :stalled}

      :run_failed ->
        # Session lifecycle error without a blocked agent window.
        if Map.get(salience, :reason_code) == "human_blocked" do
          %{section: :needs_you, reason: :blocked}
        else
          %{section: :needs_you, reason: :error}
        end

      :checks_failed ->
        %{section: :needs_you, reason: :error}

      :apply_failed ->
        %{section: :needs_you, reason: :error}

      :deploy_failed ->
        %{section: :needs_you, reason: :error}

      :run_completed ->
        %{section: :needs_you, reason: :completed}

      :deploy_succeeded ->
        %{section: :needs_you, reason: :completed}

      :approval_pending ->
        %{section: :needs_you, reason: :blocked}

      :idle ->
        %{section: :needs_you, reason: :idle}

      :working ->
        %{section: :working, reason: :working}

      _ ->
        %{section: :recent, reason: :recent}
    end
  end

  def session_classification(_), do: %{section: :recent, reason: :recent}

  @doc "Classify a session map via shared salience (convenience for projections)."
  @spec classify_session(map()) :: session_classification()
  def classify_session(session) when is_map(session) do
    session
    |> Salience.facts_from_session()
    |> Salience.compute()
    |> session_classification()
  end

  defp normalized(nil), do: ""
  defp normalized(value) when is_atom(value), do: value |> Atom.to_string() |> normalized()
  defp normalized(value), do: value |> to_string() |> String.trim() |> String.downcase()
end
