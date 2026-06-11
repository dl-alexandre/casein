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
      session_tab_title: 1
    ]

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
end
