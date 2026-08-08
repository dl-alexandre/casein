defmodule Casein.Attention.Delivery do
  @moduledoc """
  Per-surface **thresholds** over shared salience, plus focus-aware routing.

  Delivery never redefines importance. A surface may choose how high salience
  must be before it shows a badge, pins a row, or pages the operator — it may
  not invent its own ranking.

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
  @type session_reason :: :blocked | :error | :completed | :idle | :working | :recent
  @type session_classification :: %{section: session_section(), reason: session_reason()}

  # Rank floor matching today's mobile notify bands (critical/high/normal
  # actionable outcomes). Low working/informational stay below.
  @notify_rank_floor 400

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
  Whether shared salience clears the default notify threshold.

  Surfaces with a higher bar (e.g. OS push) still AND this with their own
  channel rules; they must not re-rank.
  """
  @spec notify_eligible?(Salience.t() | map()) :: boolean()
  def notify_eligible?(%{notify: notify, rank: rank})
      when is_boolean(notify) and is_integer(rank) do
    notify and rank >= @notify_rank_floor
  end

  def notify_eligible?(%{notify: notify}) when is_boolean(notify), do: notify
  def notify_eligible?(_), do: false

  @doc """
  Session-picker classification as a **projection** over salience.

  Preserves today's `SessionDirectory.Attention` membership and #696 reason
  `:idle` (agent went quiet → needs you). Does not change thresholds.
  """
  @spec session_classification(Salience.t() | map()) :: session_classification()
  def session_classification(%{signal: signal} = salience) do
    case signal do
      :agent_blocked ->
        %{section: :needs_you, reason: :blocked}

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
end
