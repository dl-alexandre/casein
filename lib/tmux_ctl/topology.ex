defmodule TmuxCtl.Topology do
  @moduledoc """
  Pure tmux session topology reads: windows, panes, and version hashes.

  No GenServer, PubSub, or application-specific audit — callers pass an
  adapter module (typically `TmuxCtl.Client` or a test fake).
  """

  @type window :: %{
          id: String.t(),
          index: non_neg_integer(),
          name: String.t(),
          active: boolean(),
          panes: pos_integer(),
          pane_list: [pane()],
          activity: non_neg_integer(),
          current_command: String.t()
        }

  @type pane :: %{
          id: String.t(),
          window_id: String.t(),
          index: non_neg_integer(),
          active: boolean(),
          left: non_neg_integer(),
          top: non_neg_integer(),
          width: non_neg_integer(),
          height: non_neg_integer(),
          current_command: String.t(),
          current_path: String.t(),
          activity: non_neg_integer(),
          activity_flag: boolean(),
          bell: boolean(),
          unseen_changes: boolean()
        }

  @type t :: %{
          :session => String.t(),
          :windows => [window()],
          :panes => [pane()],
          :active_window_id => String.t() | nil,
          :active_pane_id => String.t() | nil,
          :version => non_neg_integer(),
          :structure_version => non_neg_integer(),
          optional(:generation) => pos_integer()
        }

  @doc """
  Read topology directly from tmux (or a test adapter) without a watcher process.
  """
  @spec snapshot(String.t(), keyword()) :: t()
  def snapshot(session, opts \\ []) when is_binary(session) do
    adapter = Keyword.get(opts, :tmux, default_adapter())
    {windows, panes} = read_topology(adapter, session)
    windows = attach_panes(windows, panes)
    active = Enum.find(windows, & &1.active)
    active_pane = Enum.find(panes, & &1.active)

    %{
      session: session,
      windows: windows,
      panes: panes,
      active_window_id: active && active.id,
      active_pane_id: active_pane && active_pane.id,
      version: :erlang.phash2({windows, panes}),
      structure_version: structure_version(windows, panes)
    }
  end

  @doc """
  Hash of the topology shape only — identity, order, names, and active selection.

  Excludes per-poll churn (activity, geometry, running command) so DOM consumers
  keyed on structure are not patched on every poll.
  """
  @spec structure_version([map()], [map()]) :: non_neg_integer()
  def structure_version(windows, panes) do
    :erlang.phash2({
      Enum.map(windows, &{&1.id, &1.index, &1.name, &1.active, &1.panes}),
      Enum.map(panes, &{&1.id, &1.window_id, &1.index, &1.active})
    })
  end

  @doc false
  @spec read_topology(module(), String.t()) :: {[map()], [map()]}
  def read_topology(adapter, session) when is_atom(adapter) do
    Code.ensure_loaded!(adapter)

    if function_exported?(adapter, :session_topology, 1) do
      adapter.session_topology(session)
    else
      {adapter.list_session_windows(session), list_session_panes(adapter, session)}
    end
  end

  @doc false
  @spec attach_panes([map()], [map()]) :: [map()]
  def attach_panes(windows, panes) do
    panes_by_window = Enum.group_by(panes, & &1.window_id)

    Enum.map(windows, fn window ->
      pane_list =
        panes_by_window
        |> Map.get(window.id, [])
        |> Enum.sort_by(& &1.index)

      Map.put(window, :pane_list, pane_list)
    end)
  end

  @doc false
  @spec list_session_panes(module(), String.t()) :: [map()]
  def list_session_panes(adapter, session) when is_atom(adapter) do
    Code.ensure_loaded!(adapter)

    if function_exported?(adapter, :list_session_panes, 1) do
      adapter.list_session_panes(session)
    else
      []
    end
  end

  defp default_adapter do
    Application.get_env(:tmux_ctl, :adapter, TmuxCtl.Client)
  end
end
