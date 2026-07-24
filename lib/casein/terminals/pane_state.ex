defmodule Casein.Terminals.PaneState do
  @moduledoc """
  Derives low-cardinality agent pane state from tmux pane titles.

  Claude Code publishes useful state in `\#{pane_title}`: a Braille spinner
  while it works and a heavy asterisk when it is ready or waiting for input.
  Other agents currently fall through to `:unknown` so callers can keep their
  existing time-based fallback.
  """

  @type state :: :working | :ready | :unknown

  @ready_codepoint 0x2733

  @doc "Returns the state signalled by a pane title, or `:unknown`."
  @spec from_title(term()) :: state()
  def from_title(title) when is_binary(title) do
    title = String.trim(title)

    # Claude has also used asterisk-family spinner glyphs in pane content. Keep
    # those unknown until they are observed as title-leading markers; unknowns
    # still fall back to time-based quiet detection.
    cond do
      title == "" -> :unknown
      leading_braille_pattern?(title) -> :working
      leading_codepoint(title) == @ready_codepoint -> :ready
      true -> :unknown
    end
  end

  def from_title(_title), do: :unknown

  @doc "Extracts the human-readable task text from a title, when present."
  @spec task_summary(term()) :: String.t() | nil
  def task_summary(title) when is_binary(title) do
    title
    |> String.trim()
    |> strip_leading_state_markers()
    |> String.trim()
    |> blank_to_nil()
    |> reject_default_title()
  end

  def task_summary(_title), do: nil

  @doc "Adds `:pane_state` and `:task_summary` to a pane map."
  @spec enrich_pane(map()) :: map()
  def enrich_pane(pane) when is_map(pane) do
    title = map_get(pane, :pane_title)

    pane
    |> Map.put(:pane_state, from_title(title))
    |> Map.put(:task_summary, task_summary(title))
  end

  @doc "Adds derived pane state to every pane and window in a topology map."
  @spec enrich_topology(map()) :: map()
  def enrich_topology(%{panes: panes, windows: windows} = topology)
      when is_list(panes) and is_list(windows) do
    panes = Enum.map(panes, &enrich_pane/1)
    panes_by_id = Map.new(panes, &{map_get(&1, :id), &1})

    windows =
      Enum.map(windows, fn window ->
        pane_list =
          window
          |> window_panes()
          |> Enum.map(fn pane -> Map.get(panes_by_id, map_get(pane, :id), enrich_pane(pane)) end)

        window = Map.put(window, :pane_list, pane_list)

        window
        |> Map.put(:pane_state, window_state(window))
        |> Map.put(:task_summary, window_task_summary(window))
      end)

    %{topology | panes: panes, windows: windows}
  end

  def enrich_topology(topology) when is_map(topology), do: topology

  @doc "Returns the derived state for the role-tagged agent pane in a window."
  @spec window_state(map()) :: state()
  def window_state(window) when is_map(window) do
    case agent_or_active_pane(window) do
      nil ->
        :unknown

      pane ->
        case normalize_state(map_get(pane, :pane_state)) do
          state when state in [:working, :ready] -> state
          _state -> from_title(map_get(pane, :pane_title))
        end
    end
  end

  def window_state(_window), do: :unknown

  @doc "Returns the preferred task summary for the role-tagged agent pane."
  @spec window_task_summary(map()) :: String.t() | nil
  def window_task_summary(window) when is_map(window) do
    case agent_or_active_pane(window) do
      nil ->
        nil

      pane ->
        blank_to_nil(map_get(pane, :task_summary)) || task_summary(map_get(pane, :pane_title))
    end
  end

  def window_task_summary(_window), do: nil

  @doc "Finds the role-tagged agent pane, falling back to the active pane."
  @spec agent_or_active_pane(map()) :: map() | nil
  def agent_or_active_pane(window) when is_map(window) do
    panes = window_panes(window)

    Enum.find(panes, &agent_role?/1) ||
      Enum.find(panes, &truthy?(map_get(&1, :active))) ||
      List.first(panes)
  end

  def agent_or_active_pane(_window), do: nil

  @doc "True when a pane is marked as the Casein agent pane."
  @spec agent_role?(map()) :: boolean()
  def agent_role?(pane) when is_map(pane), do: map_get(pane, :role) == "agent"
  def agent_role?(_pane), do: false

  @doc "Returns panes embedded in a topology window map."
  @spec window_panes(map()) :: [map()]
  def window_panes(window) when is_map(window) do
    case map_get(window, :pane_list) do
      panes when is_list(panes) -> panes
      _ -> []
    end
  end

  def window_panes(_window), do: []

  @doc false
  def map_get(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  def map_get(_map, _key), do: nil

  defp normalize_state(state) when state in [:working, :ready, :unknown], do: state
  defp normalize_state("working"), do: :working
  defp normalize_state("ready"), do: :ready
  defp normalize_state("unknown"), do: :unknown
  defp normalize_state(_state), do: nil

  # tmux defaults a pane's title to the local hostname until an application
  # sets one via OSC 0/2, so a hostname-valued title carries no task signal.
  defp reject_default_title(nil), do: nil

  defp reject_default_title(summary) do
    if summary == local_hostname(), do: nil, else: summary
  end

  defp local_hostname do
    case :inet.gethostname() do
      {:ok, name} -> List.to_string(name)
      _ -> nil
    end
  end

  defp strip_leading_state_markers(<<codepoint::utf8, rest::binary>>)
       when (codepoint >= 0x2800 and codepoint <= 0x28FF) or codepoint == 0x2733 do
    rest
    |> String.trim_leading()
    |> strip_leading_state_markers()
  end

  defp strip_leading_state_markers(title), do: title

  defp leading_braille_pattern?(title) do
    case leading_codepoint(title) do
      codepoint when is_integer(codepoint) -> codepoint >= 0x2800 and codepoint <= 0x28FF
      _ -> false
    end
  end

  defp leading_codepoint(<<codepoint::utf8, _rest::binary>>), do: codepoint
  defp leading_codepoint(_title), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  defp truthy?(value) when value in [true, 1, "1", "true", "yes", "on"], do: true
  defp truthy?(_value), do: false
end
