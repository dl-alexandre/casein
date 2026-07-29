defmodule Casein.Mobile.LiveWork do
  @moduledoc """
  Privacy-safe live-work projection over the canonical terminal session list.

  This module deliberately consumes only typed session/window state and a small
  metadata allowlist. It never projects pane titles, commands, cwd values,
  transcript text, terminal output, or operator activity.
  """

  alias Casein.Mobile.Card
  alias Casein.Terminals.Session.Info

  @max_title 120
  @max_agent 48
  @max_ref 160
  @active_states ~w(working blocked ready)

  @spec project(String.t(), String.t(), String.t(), [Info.t()], DateTime.t()) :: [Card.t()]
  def project(user_id, workspace_id, workspace_name, tabs, now \\ DateTime.utc_now())
      when is_binary(user_id) and is_binary(workspace_id) and is_list(tabs) do
    tabs
    |> Enum.filter(&eligible?/1)
    |> Enum.map(&card(user_id, workspace_id, workspace_name, &1, now))
    |> Enum.reject(&is_nil/1)
  end

  defp eligible?(%Info{status: status}) when status not in [:active, nil], do: false

  defp eligible?(%Info{kind: :agent}), do: true

  defp eligible?(%Info{metadata: metadata}) when is_map(metadata) do
    present?(value(metadata, :runtime_id)) or
      present?(value(metadata, :agent)) or
      windows(metadata) |> Enum.any?(&present?(value(&1, :conversation_title))) or
      explicitly_reported_agent?(metadata)
  end

  defp eligible?(_tab), do: false

  # A scanned shell becomes agent work only when two independent authoritative
  # signals agree in the same window: topology has an explicit role-marked
  # agent pane and the session directory resolved a typed semantic state for
  # that window.
  # Neither a focused pane nor an unmarked state is enough.
  defp explicitly_reported_agent?(metadata) do
    metadata
    |> reported_agent_windows()
    |> Enum.any?(fn window ->
      normalize(value(window, :agent_state)) in @active_states
    end)
  end

  defp card(user_id, workspace_id, workspace_name, %Info{} = tab, now) do
    metadata = tab.metadata || %{}
    windows = projection_windows(tab, metadata)
    state = aggregate_state(windows)
    phase = phase(state)
    agent = bounded(value(metadata, :agent), @max_agent) || inferred_agent(windows)
    title = conversation_title(windows) || agent_title(agent)
    activity = activity(state)
    session_id = stable_session_id(tab)

    if is_binary(session_id) do
      Card.live_work(
        %{
          user_id: user_id,
          workspace_id: workspace_id,
          workspace_name: workspace_name,
          session_id: session_id,
          title: title,
          body: live_body(agent, activity),
          status: status(state),
          phase: phase,
          activity: activity,
          reason: if(state == :blocked, do: "blocked"),
          agent: agent,
          branch: bounded(value(metadata, :git_branch), @max_ref),
          head_sha: bounded(value(metadata, :git_head_sha), @max_ref),
          progress: progress(windows),
          partial: state == :unknown,
          locator: locator(tab)
        },
        now
      )
    end
  end

  defp aggregate_state(windows) do
    states =
      Enum.flat_map(windows, fn window ->
        [normalize(value(window, :agent_state)), normalize(value(window, :pane_state))]
      end)

    cond do
      "blocked" in states -> :blocked
      Enum.any?(states, &(&1 in ~w(failed error))) -> :failed
      "working" in states -> :working
      Enum.any?(states, &(&1 in @active_states)) -> :ready
      true -> :unknown
    end
  end

  defp phase(:blocked), do: "waiting"
  defp phase(:working), do: "executing"
  defp phase(:failed), do: "failed"
  defp phase(:ready), do: "ready"
  defp phase(:unknown), do: "unknown"

  defp status(:failed), do: "failed"
  defp status(:blocked), do: "waiting"
  defp status(_state), do: "running"

  defp activity(:blocked), do: "Waiting for user"
  defp activity(:working), do: "Agent working"
  defp activity(:failed), do: "Work reported a failure"
  defp activity(:ready), do: "Agent ready"
  defp activity(:unknown), do: "Activity details unavailable"

  defp live_body(nil, activity), do: activity
  defp live_body(agent, activity), do: "#{agent} · #{activity}"

  defp agent_title(nil), do: "Agent work"
  defp agent_title(agent), do: "#{agent} work"

  defp inferred_agent(windows) do
    if Enum.any?(windows, &present?(value(&1, :conversation_title))), do: "Codex"
  end

  defp conversation_title(windows) do
    Enum.find_value(windows, fn window ->
      bounded(value(window, :conversation_title), @max_title)
    end)
  end

  defp progress(windows) do
    counts =
      Enum.reduce(windows, %{working: 0, waiting: 0, ready: 0, unknown: 0}, fn window, acc ->
        state =
          normalize(value(window, :agent_state)) ||
            normalize(value(window, :pane_state)) ||
            "unknown"

        bucket =
          case state do
            "working" -> :working
            "blocked" -> :waiting
            "ready" -> :ready
            _ -> :unknown
          end

        Map.update!(acc, bucket, &(&1 + 1))
      end)

    Map.put(counts, :windows, length(windows))
  end

  defp locator(tab) do
    metadata = tab.metadata || %{}

    %{
      tmux_session: bounded(tab.tmux_session, @max_ref),
      pane: unique_agent_pane(metadata),
      tab: "terminal"
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  # A pane id becomes part of the navigation locator only when topology exposes
  # exactly one explicitly role-marked agent pane for the projected session.
  # Active/focused panes and command heuristics are deliberately ignored: the
  # locator remains navigation data, and mutation still revalidates the role.
  defp unique_agent_pane(metadata) do
    metadata
    |> explicit_agent_panes()
    |> case do
      [pane] -> pane
      _none_or_ambiguous -> nil
    end
  end

  defp explicit_agent_panes(metadata) do
    metadata
    |> explicit_agent_pane_summaries()
    |> Enum.map(&value(&1, :id))
    |> Enum.map(&bounded(&1, @max_ref))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp explicit_agent_pane_summaries(metadata) do
    case value(metadata, :pane_summaries) do
      summaries when is_list(summaries) ->
        summaries
        |> Enum.filter(&is_map/1)
        |> Enum.filter(&(normalize(value(&1, :role)) == "agent"))

      _missing ->
        []
    end
  end

  defp reported_agent_windows(metadata) do
    agent_window_ids =
      metadata
      |> explicit_agent_pane_summaries()
      |> Enum.map(&(value(&1, :window_id) |> bounded(@max_ref)))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    metadata
    |> windows()
    |> Enum.filter(fn window ->
      window_id = value(window, :id) |> bounded(@max_ref)
      is_binary(window_id) and MapSet.member?(agent_window_ids, window_id)
    end)
  end

  # Once a scanned shell has a correlated role-marked agent window, unrelated
  # operator/verify windows cannot contribute state, progress, or titles to its
  # mobile projection. Native agent sessions retain their existing aggregation.
  defp projection_windows(%Info{kind: :shell}, metadata) do
    case reported_agent_windows(metadata) do
      [] -> windows(metadata)
      agent_windows -> agent_windows
    end
  end

  defp projection_windows(_tab, metadata), do: windows(metadata)

  defp stable_session_id(%Info{id: id}) when is_binary(id) and id != "", do: bounded(id, @max_ref)

  defp stable_session_id(%Info{sid: sid}) when is_binary(sid) and sid != "",
    do: bounded(sid, @max_ref)

  defp stable_session_id(_tab), do: nil

  defp windows(metadata) do
    case value(metadata, :windows) do
      windows when is_list(windows) -> Enum.filter(windows, &is_map/1)
      _value -> []
    end
  end

  defp bounded(nil, _max), do: nil

  defp bounded(value, max) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> String.slice(text, 0, max)
    end
  end

  defp bounded(value, max) when is_atom(value), do: value |> Atom.to_string() |> bounded(max)
  defp bounded(_value, _max), do: nil

  defp normalize(nil), do: nil
  defp normalize(value) when is_atom(value), do: value |> Atom.to_string() |> normalize()
  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize(_value), do: nil

  defp present?(value), do: is_binary(bounded(value, @max_ref))

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
