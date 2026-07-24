defmodule Casein.Agents.PreviewTools.TmuxTopology do
  @moduledoc false

  alias Casein.Agents.AgentPane
  alias Casein.Agents.PreviewTools.ControlSession
  alias Casein.PreviewPanes
  alias Casein.Previews.Deps

  defdelegate split_preview_pane(workspace, url, opts), to: ControlSession

  def ensure_pane_tmux_session_scope(pane_id, opts) do
    case Keyword.get(opts, :tmux_session) do
      session when is_binary(session) and session != "" ->
        case PreviewPanes.get_by_pane(pane_id) do
          %{tmux_session: ^session} -> :ok
          _ -> {:error, :not_found}
        end

      _ ->
        :ok
    end
  end

  def ensure_pane_placement_scope(pane_id, opts) do
    case {Keyword.get(opts, :tmux_session), Keyword.get(opts, :anchor_window_id)} do
      {tmux_session, anchor_window_id}
      when is_binary(tmux_session) and tmux_session != "" and is_binary(anchor_window_id) and
             anchor_window_id != "" ->
        current_window_id = pane_window_id(tmux_session, pane_id)

        if current_window_id in [nil, anchor_window_id] do
          :ok
        else
          registration = PreviewPanes.get_by_pane(pane_id)

          {:error,
           {:preview_misplaced, registration,
            %{
              pane_id: pane_id,
              current_window_id: current_window_id,
              expected_window_id: anchor_window_id
            }}}
        end

      _ ->
        :ok
    end
  end

  def repair_misplaced_preview_pane(%{pane_id: pane_id, tmux_session: tmux_session})
      when is_binary(pane_id) and is_binary(tmux_session) do
    _ = terminals().kill_pane(tmux_session, pane_id)
    _ = PreviewPanes.deregister(pane_id)
    :ok
  end

  def repair_misplaced_preview_pane(_), do: :ok

  def resolve_preview_placement(tmux_session, params) do
    case string_param(params, :anchor_pane_id) do
      pane_id when is_binary(pane_id) ->
        {:ok,
         %{
           placement: "beside_agent",
           anchor_pane_id: pane_id,
           anchor_window_id: pane_window_id(tmux_session, pane_id),
           anchor_match: "explicit"
         }}

      _ ->
        with {:ok, pane} <-
               AgentPane.find(tmux_session, terminals().adapter(), allow_process_fallback: true) do
          {:ok,
           %{
             placement: "beside_agent",
             anchor_pane_id: pane.id,
             anchor_window_id: pane_window_id(tmux_session, pane.id) || Map.get(pane, :window_id),
             anchor_match: Map.get(pane, :agent_match)
           }}
        end
    end
  end

  def pane_window_id(tmux_session, pane_id)
      when is_binary(tmux_session) and is_binary(pane_id) do
    tmux_session
    |> terminals().list_session_panes()
    |> Enum.find(&(Map.get(&1, :id) == pane_id))
    |> case do
      %{window_id: window_id} -> window_id
      %{"window_id" => window_id} -> window_id
      _ -> nil
    end
  end

  def pane_window_id(_tmux_session, _pane_id), do: nil

  def placement_payload(registration) when is_map(registration) do
    %{
      placement: Map.get(registration, :placement),
      anchor_pane_id: Map.get(registration, :anchor_pane_id),
      anchor_window_id: Map.get(registration, :anchor_window_id),
      pane_id: Map.get(registration, :pane_id),
      pane_window_id: Map.get(registration, :pane_window_id)
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp string_param(params, key) do
    case Map.get(params, Atom.to_string(key)) || Map.get(params, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp terminals, do: Deps.impl(:terminals)
end
