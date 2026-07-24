defmodule Casein.Previews.Deps.Terminals do
  @moduledoc """
  Preview-owned seam for tmux session/pane ops and topology subscriptions.

  The production impl owns the `:tmux_adapter` env read so preview modules
  never carry a compile-time default naming `Casein.Terminals.Tmux`.
  """

  @callback list_sessions() :: [map()]
  @callback list_session_panes(session :: String.t()) :: [map()]
  @callback capture_scrollback(session :: String.t(), opts :: keyword()) :: term()
  @callback workspace_session_prefix(workspace_name :: String.t()) :: String.t()
  @callback session_name(workspace_name :: String.t(), sid :: String.t()) :: String.t()
  @callback topology_subscribe(session :: String.t()) :: term()
  @callback topology_refresh(session :: String.t()) :: term()
  @callback topology_get(session :: String.t(), opts :: keyword()) :: term()
  @callback kill_pane(session :: String.t(), pane_id :: String.t()) :: term()
  @callback split_pane(
              session :: String.t(),
              pane_id :: String.t(),
              direction :: String.t(),
              opts :: keyword()
            ) :: term()
  @callback select_pane(session :: String.t(), pane_id :: String.t()) :: term()
  @callback adapter() :: module()
end
