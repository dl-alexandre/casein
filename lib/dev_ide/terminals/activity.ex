defmodule Casein.Terminals.Activity do
  @moduledoc """
  tmux `monitor-silence` analog for agent windows.

  A window is "quiet" when its role-tagged agent pane is ready, or when that
  pane has been silent longer than the silence threshold but is still inside
  the attention window. Role metadata is the ground truth; process names are
  only a legacy compatibility fallback for older topology maps that do not
  carry pane roles yet.

  Quantizing the volatile activity timestamp into this boolean is what lets
  `SessionDirectory` store it in the stable window metadata: the flip (and
  only the flip) re-broadcasts the tab list, so quiet-agent notifications
  reach LiveViews without per-poll churn from raw timestamps.
  """

  alias Casein.Terminals.Boundary
  alias Casein.Terminals.PaneState

  @silence_after_seconds 60
  @attention_window_seconds 1_800

  @doc """
  True when the window's agent pane needs attention.

  Accepts topology windows with `pane_list` and older window maps produced by
  `Tmux.list_session_windows/1` (atom or string keys; integer or string
  timestamps).
  """
  @spec agent_window_quiet?(map(), integer()) :: boolean()
  def agent_window_quiet?(window, now \\ now_unix()) when is_map(window) do
    case PaneState.window_state(window) do
      :ready ->
        window
        |> quiet_candidate_pane()
        |> pane_in_attention_window?(now)

      :working ->
        false

      :unknown ->
        window
        |> quiet_candidate_pane()
        |> pane_quiet?(now)
    end
  end

  @doc "Returns the pane used for time-based quiet detection, when known."
  @spec quiet_candidate_pane(map()) :: map() | nil
  def quiet_candidate_pane(window) when is_map(window) do
    panes = PaneState.window_panes(window)

    Enum.find(panes, &PaneState.agent_role?/1) ||
      Enum.find(panes, &(truthy?(PaneState.map_get(&1, :active)) and legacy_agent_command?(&1))) ||
      legacy_window_pane(window)
  end

  def quiet_candidate_pane(_window), do: nil

  @doc "True for commands that launch an interactive coding agent."
  @spec agent_command?(term()) :: boolean()
  def agent_command?(command) when is_binary(command),
    do: command in Boundary.interactive_command_ids()

  def agent_command?(_command), do: false

  defp pane_quiet?(nil, _now), do: false

  defp pane_quiet?(pane, now) when is_map(pane) do
    with {:ok, timestamp} when timestamp > 0 <-
           parse_timestamp(PaneState.map_get(pane, :activity)) do
      age = now - timestamp
      age >= @silence_after_seconds and age <= @attention_window_seconds
    else
      _ -> false
    end
  end

  defp pane_in_attention_window?(nil, _now), do: false

  defp pane_in_attention_window?(pane, now) when is_map(pane) do
    with {:ok, timestamp} when timestamp > 0 <-
           parse_timestamp(PaneState.map_get(pane, :activity)) do
      age = now - timestamp
      age >= 0 and age <= @attention_window_seconds
    else
      _ -> false
    end
  end

  defp legacy_agent_command?(pane) when is_map(pane) do
    pane
    |> PaneState.map_get(:current_command)
    |> agent_command?()
  end

  defp legacy_agent_command?(_pane), do: false

  defp legacy_window_pane(window) do
    if PaneState.window_panes(window) == [] and legacy_agent_command?(window) do
      window
    end
  end

  defp parse_timestamp(value) when is_integer(value), do: {:ok, value}

  defp parse_timestamp(value) when is_binary(value) do
    case Integer.parse(value) do
      {timestamp, ""} -> {:ok, timestamp}
      _ -> :error
    end
  end

  defp parse_timestamp(_value), do: :error

  defp truthy?(value) when value in [true, 1, "1", "true", "yes", "on"], do: true
  defp truthy?(_value), do: false

  defp now_unix, do: DateTime.utc_now() |> DateTime.to_unix()
end
