defmodule Casein.Terminals.AgentPane do
  @moduledoc """
  Resolves the role-marked agent pane in a Casein tmux session.

  The `agent_pair` template persists `@devide_pane_role=agent`; this module is
  the terminal-layer lookup that callers can use before sending agent-only
  input. It deliberately avoids process-name guessing so a missing layout
  produces a clear operator-facing failure instead of targeting the wrong pane.
  """

  @agent_role "agent"

  @type result :: map()
  @type error :: %{
          error: :agent_pane_not_found,
          message: String.t(),
          suggested_template: String.t(),
          required_role: String.t(),
          auto_apply_option: atom(),
          candidate_panes: [map()]
        }

  @doc """
  Find the pane marked with `role: "agent"` in `session`.
  """
  @spec find(String.t(), keyword()) :: {:ok, result()} | {:error, error()}
  def find(session, opts \\ []) when is_binary(session) and is_list(opts) do
    tmux = Keyword.get(opts, :tmux, Casein.Terminals.tmux_adapter())
    panes = tmux.list_session_panes(session)

    case Enum.find(panes, &agent_role?/1) do
      nil -> {:error, agent_pane_not_found_error(panes)}
      pane -> {:ok, Map.put(pane, :agent_match, "pane_role")}
    end
  end

  @doc """
  Summarize whether a set of sessions has a role-marked agent pane.

  This is intended for export/status payloads, so pane summaries avoid cwd and
  other host-path fields.
  """
  @spec layout_status([map()], keyword()) :: map()
  def layout_status(sessions, opts \\ []) when is_list(sessions) and is_list(opts) do
    tmux = Keyword.get(opts, :tmux, Casein.Terminals.tmux_adapter())

    candidate_sessions =
      sessions
      |> Enum.map(&session_layout_status(&1, tmux))
      |> Enum.reject(&is_nil/1)

    agent_panes = Enum.flat_map(candidate_sessions, &Map.get(&1, :agent_panes, []))

    status =
      cond do
        candidate_sessions == [] -> "no_sessions"
        agent_panes != [] -> "ready"
        true -> "missing_agent_pane"
      end

    %{
      status: status,
      ready: status == "ready",
      required_role: @agent_role,
      suggested_template: "agent_pair",
      auto_apply_option: "auto_apply_agent_pair",
      sessions_checked: length(candidate_sessions),
      agent_panes: agent_panes,
      candidate_sessions: candidate_sessions
    }
  end

  defp agent_role?(%{role: @agent_role}), do: true
  defp agent_role?(%{"role" => @agent_role}), do: true
  defp agent_role?(_pane), do: false

  defp agent_pane_not_found_error(panes) do
    %{
      error: :agent_pane_not_found,
      message: "Apply the agent_pair template before using agent-pane tools.",
      suggested_template: "agent_pair",
      required_role: @agent_role,
      auto_apply_option: :auto_apply_agent_pair,
      candidate_panes:
        Enum.map(panes, &Map.take(&1, [:id, :active, :current_command, :current_path, :role]))
    }
  end

  defp session_layout_status(session, tmux) do
    with tmux_session when is_binary(tmux_session) and tmux_session != "" <-
           map_get(session, :tmux_session) do
      panes =
        case session_pane_summaries(session) do
          [_ | _] = summaries -> Enum.map(summaries, &safe_pane/1)
          _ -> tmux_session |> tmux.list_session_panes() |> Enum.map(&safe_pane/1)
        end

      agent_panes = Enum.filter(panes, &agent_role?/1)

      %{
        id: map_get(session, :id),
        label: map_get(session, :label),
        tmux_session: tmux_session,
        status: if(agent_panes == [], do: "missing_agent_pane", else: "ready"),
        pane_count: length(panes),
        agent_panes: agent_panes,
        candidate_panes: panes
      }
      |> compact_map()
    else
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp safe_pane(pane) when is_map(pane) do
    %{
      id: map_get(pane, :id),
      window_id: map_get(pane, :window_id),
      index: map_get(pane, :index),
      active: map_get(pane, :active),
      current_command: map_get(pane, :current_command),
      role: map_get(pane, :role)
    }
    |> compact_map()
  end

  defp safe_pane(_pane), do: %{}

  defp session_pane_summaries(session) do
    metadata = map_get(session, :metadata) || %{}

    case map_get(metadata, :pane_summaries) do
      summaries when is_list(summaries) -> summaries
      _ -> []
    end
  end

  defp map_get(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end
end
