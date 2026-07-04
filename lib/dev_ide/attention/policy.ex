defmodule DevIDE.Attention.Policy do
  @moduledoc """
  Pure attention-routing rules for operator-facing agent state.

  Callers gather facts from their own layer (browser focus, LiveView session,
  tmux topology) and pass only low-cardinality values here. The policy returns a
  small reaction enum so UI surfaces can stay consistent: stay quiet, render
  inline chrome, or ask the browser for an OS notification.
  """

  @type surface_state :: :focused | :visible | :hidden | :unknown
  @type target_state :: :focused | :visible | :hidden | :unknown
  @type reaction :: :nothing | :inline | :notify
  @type quiet_reason ::
          :cold_ready
          | :focused_target
          | :focused_workspace
          | :background_surface

  @type quiet_decision :: %{
          reaction: reaction(),
          reason: quiet_reason(),
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
  @spec quiet_agent_transition(map()) :: reaction()
  def quiet_agent_transition(attrs) when is_map(attrs) do
    attrs
    |> quiet_agent_decision()
    |> Map.fetch!(:reaction)
  end

  @doc """
  Full quiet-agent decision with normalized inputs and a reason for telemetry.
  """
  @spec quiet_agent_decision(map()) :: quiet_decision()
  def quiet_agent_decision(attrs) when is_map(attrs) do
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
  @spec quiet_agent_window(map()) :: reaction()
  def quiet_agent_window(attrs) when is_map(attrs) do
    if Map.get(attrs, :quiet?) == true, do: :inline, else: :nothing
  end

  @doc "JSON-safe reaction label for browser payloads and data attributes."
  @spec reaction_label(reaction()) :: String.t()
  def reaction_label(:nothing), do: "nothing"
  def reaction_label(:inline), do: "inline"
  def reaction_label(:notify), do: "notify"
end
