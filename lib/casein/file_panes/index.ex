defmodule Casein.FilePanes.Index do
  @moduledoc """
  Pure workspace/window index math and ETS reads for file panes.

  GenServer wrappers in `Casein.FilePanes` still own state commits (ETS insert,
  index field updates, topology subscribe). This module only computes next map
  values and performs public ETS lookups against the GenServer-owned table.
  """

  @table :casein_file_panes

  def lookup(pane_id) when is_binary(pane_id) do
    case :ets.lookup(@table, pane_id) do
      [{^pane_id, registration}] -> registration
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  def put_workspace(idx, pane_id, workspace_id) do
    ids =
      idx
      |> Map.get(workspace_id, [])
      |> then(&Enum.uniq([pane_id | &1]))

    Map.put(idx, workspace_id, ids)
  end

  def drop_workspace(idx, pane_id, workspace_id) do
    ids =
      idx
      |> Map.get(workspace_id, [])
      |> Enum.reject(&(&1 == pane_id))

    if ids == [],
      do: Map.delete(idx, workspace_id),
      else: Map.put(idx, workspace_id, ids)
  end

  def put_window(idx, %{
        tmux_session: session,
        pane_window_id: window_id,
        pane_id: pane_id
      })
      when is_binary(session) and is_binary(window_id) do
    Map.put(idx, {session, window_id}, pane_id)
  end

  def put_window(idx, _reg), do: idx

  def drop_window(idx, %{tmux_session: session, pane_window_id: window_id})
      when is_binary(session) and is_binary(window_id) do
    Map.delete(idx, {session, window_id})
  end

  def drop_window(idx, _reg), do: idx

  def refresh_window(idx, session, panes) do
    by_id = Map.new(panes, &{&1.id, &1})

    idx
    |> Enum.reduce(%{}, fn
      {{^session, _window_id}, pane_id} = entry, acc ->
        case Map.get(by_id, pane_id) do
          %{window_id: current_window} when is_binary(current_window) ->
            Map.put(acc, {session, current_window}, pane_id)

          _ ->
            # pane gone — drop it; expire pass will deregister the registration
            _ = entry
            acc
        end

      {key, pane_id}, acc ->
        Map.put(acc, key, pane_id)
    end)
  end

  def list_registrations(workspace_index, workspace_ids) do
    workspace_ids
    |> Enum.flat_map(&Map.get(workspace_index, &1, []))
    |> Enum.uniq()
    |> Enum.map(&lookup/1)
    |> Enum.reject(&is_nil/1)
  end
end
