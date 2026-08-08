defmodule Casein.Attention.Policy do
  @moduledoc """
  Pure attention-routing rules for operator-facing agent state.

  Callers gather facts from their own layer (browser focus, LiveView session,
  tmux topology) and pass only low-cardinality values here. The policy returns a
  small reaction enum so UI surfaces can stay consistent: stay quiet, render
  inline chrome, or ask the browser for an OS notification.

  ## `delivery_*` means how (or whether) to surface a signal

  `delivery_reason`, `delivery_decision/1`, `delivery_reaction/1`, and
  `window_delivery/1` answer *suppress / inline / notify* for an already-known
  operator-facing transition. A `delivery_reason` of `:focused_target` means
  "do not page the operator" — not "the agent is idle".

  It deliberately does **not** mean "an agent has gone quiet, therefore you are
  needed". That session-picker signal is `Casein.Terminals.SessionDirectory.Attention`
  reason `:idle` (raised from the directory window's `:quiet` flag). Do not
  reuse `:idle` or name delivery helpers `quiet_*`.
  """

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
  Attention reaction for a quiet-agent transition.

  `observed_working?` must be true before an OS notification is considered. A
  cold ready window still gets inline chrome, but it should not page the
  operator just because they loaded or reconnected to the workspace.
  """
  @spec delivery_reaction(map()) :: reaction()
  def delivery_reaction(attrs) when is_map(attrs) do
    attrs
    |> delivery_decision()
    |> Map.fetch!(:reaction)
  end

  @doc """
  Full delivery decision with normalized inputs and a reason for telemetry.

  Names the suppress/inline/notify choice for a quiet-agent transition — not
  the session-picker `:idle` reason.
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
end
