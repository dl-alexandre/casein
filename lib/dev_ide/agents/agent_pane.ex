defmodule DevIDE.Agents.AgentPane do
  @moduledoc """
  Resolves the dedicated agent pane in a DevIDE tmux session.

  When the caller is itself a pane in the session (`:exclude_pane` /
  `:prefer_window_of`), resolution anchors to the caller: panes sharing the
  caller's window are matched first, and the caller's own pane is never
  returned — an agent asking for "the agent pane" wants a peer, not itself.
  """

  @agent_marker "DevIDE agent pane"
  @agent_processes ~w(claude grok codex opencode)

  @spec find(String.t(), module(), keyword()) :: {:ok, map()} | {:error, map()}
  def find(session, tmux, opts \\ []) when is_binary(session) and is_atom(tmux) do
    allow_process_fallback = Keyword.get(opts, :allow_process_fallback, true)
    exclude = Keyword.get(opts, :exclude_pane)
    prefer_window_of = Keyword.get(opts, :prefer_window_of)

    panes = tmux.list_session_panes(session)

    candidates =
      panes
      |> order_by_caller_window(prefer_window_of)
      |> Enum.reject(&(is_binary(exclude) and &1.id == exclude))

    case match_agent_pane(session, tmux, candidates, allow_process_fallback) do
      nil ->
        if is_binary(exclude) and
             caller_was_only_match?(session, tmux, panes, exclude, allow_process_fallback) do
          {:error, caller_only_agent_pane_error(exclude, panes)}
        else
          {:error, agent_pane_not_found_error(panes, allow_process_fallback)}
        end

      pane ->
        {:ok, pane}
    end
  end

  # Panes in the caller's window are checked first so multi-window sessions
  # with several agent panes resolve to the caller's neighbor, not whichever
  # pane tmux happened to list first.
  defp order_by_caller_window(panes, prefer_window_of) when is_binary(prefer_window_of) do
    case Enum.find(panes, &(&1.id == prefer_window_of)) do
      %{window_id: window_id} ->
        {same_window, rest} = Enum.split_with(panes, &(&1.window_id == window_id))
        same_window ++ rest

      _ ->
        panes
    end
  end

  defp order_by_caller_window(panes, _prefer_window_of), do: panes

  defp match_agent_pane(session, tmux, panes, allow_process_fallback) do
    marker_agent_pane(session, tmux, panes) ||
      if(allow_process_fallback, do: process_agent_pane(panes), else: nil)
  end

  defp caller_was_only_match?(session, tmux, panes, exclude, allow_process_fallback) do
    caller = Enum.filter(panes, &(&1.id == exclude))

    caller != [] and
      match_agent_pane(session, tmux, caller, allow_process_fallback) != nil
  end

  defp marker_agent_pane(session, tmux, panes) do
    Enum.find_value(panes, fn pane ->
      if pane_has_agent_marker?(session, tmux, pane),
        do: Map.put(pane, :agent_match, "agent_pair_marker")
    end)
  end

  defp process_agent_pane(panes) do
    Enum.find_value(panes, fn pane ->
      if agent_process?(pane), do: Map.put(pane, :agent_match, "agent_process")
    end)
  end

  defp pane_has_agent_marker?(session, tmux, %{id: pane_id}) do
    session
    |> tmux.capture_scrollback(target: pane_id, lines: 50, ansi: false)
    |> String.contains?(@agent_marker)
  end

  defp agent_process?(%{current_command: command}) when is_binary(command) do
    command = String.downcase(command)
    Enum.any?(@agent_processes, &String.contains?(command, &1))
  end

  defp agent_process?(_), do: false

  defp agent_pane_not_found_error(panes, allow_process_fallback) do
    %{
      error: :agent_pane_not_found,
      message: agent_pane_not_found_message(allow_process_fallback),
      candidate_panes:
        Enum.map(panes, &Map.take(&1, [:id, :active, :current_command, :current_path]))
    }
  end

  defp caller_only_agent_pane_error(caller_pane, panes) do
    %{
      error: :caller_is_only_agent_pane,
      caller_pane: caller_pane,
      message:
        "The only agent pane in this session is the caller's own pane. " <>
          "Agent-pane tools target a peer agent; pass an explicit pane id to target another pane.",
      candidate_panes:
        Enum.map(panes, &Map.take(&1, [:id, :active, :current_command, :current_path]))
    }
  end

  defp agent_pane_not_found_message(true) do
    "Apply the agent_pair template or run the agent in this tmux session before targeting the agent pane."
  end

  defp agent_pane_not_found_message(false) do
    "Apply the agent_pair template before using agent-pane tools."
  end
end
