defmodule DevIdeWeb.WorkspaceLive.Show.SessionBarVM do
  @moduledoc """
  Pure view-model builder for the terminal session bar.

  Maps domain `Session.Info` structs to render-ready maps so the templates do
  no business logic. The `dom_id` preserves the historical
  `"active_sessions-<id>"` ids (from the former LiveView stream) that tests
  and tooling select on.

  Whether a tab is the active one is intentionally NOT part of the
  view-model: templates compare `tab.id` against the current `@terminal_sid`
  so switching sessions re-styles tabs without rebuilding the list.
  """

  alias DevIDE.Terminals.Session.Info, as: SessionInfo

  import DevIdeWeb.WorkspaceLive.Show.TerminalChrome,
    only: [
      session_attach_id: 1,
      session_kind_label: 1,
      session_tab_detail: 1,
      session_tab_title: 1,
      window_activity_state: 1,
      window_activity_class: 1,
      window_activity_label: 1,
      window_full_title: 1
    ]

  import DevIdeWeb.WorkspaceLive.Show.UI, only: [dom_fragment: 1]

  @type tab :: %{
          id: String.t(),
          dom_id: String.t(),
          kind: atom(),
          label: String.t(),
          detail: String.t(),
          title: String.t(),
          tmux_session: String.t() | nil
        }

  @spec session_tabs([SessionInfo.t()]) :: [tab()]
  def session_tabs(infos) when is_list(infos), do: Enum.map(infos, &session_tab/1)

  @spec session_tab(SessionInfo.t()) :: tab()
  def session_tab(%SessionInfo{} = info) do
    id = session_attach_id(info)

    %{
      id: id,
      dom_id: "active_sessions-" <> id,
      kind: info.kind,
      label: session_kind_label(info.kind),
      detail: session_tab_detail(info),
      title: session_tab_title(info),
      tmux_session: info.tmux_session
    }
  end

  @type window_tab :: %{
          id: String.t(),
          dom_frag: String.t(),
          index: integer() | nil,
          name: String.t(),
          active?: boolean(),
          activity_state: :fresh | :recent | :idle,
          activity_class: String.t(),
          activity_label: String.t(),
          command: String.t() | nil,
          full_title: String.t()
        }

  @doc """
  Maps raw tmux topology windows (as produced by `TmuxTopology.snapshot/2`)
  to render-ready window tabs. Activity state is baked in because window
  data only changes via topology updates, which rebuild this list anyway.
  """
  @spec window_tabs([map()]) :: [window_tab()]
  def window_tabs(windows) when is_list(windows), do: Enum.map(windows, &window_tab/1)

  def window_tab(window) do
    activity_state = window_activity_state(window)

    %{
      id: window.id,
      dom_frag: dom_fragment(window.id),
      index: window.index,
      name: window.name,
      active?: window.active,
      activity_state: activity_state,
      activity_class: window_activity_class(activity_state),
      activity_label: window_activity_label(activity_state),
      command: window.current_command,
      full_title: window_full_title(window)
    }
  end
end
