defmodule DevIDE.Agents.AgentPane do
  @moduledoc """
  Resolves the dedicated agent pane in a DevIDE tmux session.
  """

  @agent_marker "DevIDE agent pane"
  @agent_processes ~w(claude grok codex opencode)

  @spec find(String.t(), module(), keyword()) :: {:ok, map()} | {:error, map()}
  def find(session, tmux, opts \\ []) when is_binary(session) and is_atom(tmux) do
    allow_process_fallback = Keyword.get(opts, :allow_process_fallback, true)
    panes = tmux.list_session_panes(session)

    pane =
      marker_agent_pane(session, tmux, panes) ||
        if(allow_process_fallback, do: process_agent_pane(panes), else: nil)

    case pane do
      nil -> {:error, agent_pane_not_found_error(panes, allow_process_fallback)}
      pane -> {:ok, pane}
    end
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

  defp agent_pane_not_found_message(true) do
    "Apply the agent_pair template or run the agent in this tmux session before targeting the agent pane."
  end

  defp agent_pane_not_found_message(false) do
    "Apply the agent_pair template before using agent-pane tools."
  end
end
