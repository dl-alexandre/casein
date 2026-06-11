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
  alias DevIdeWeb.WorkspaceLive.Show.TerminalChrome

  import DevIdeWeb.WorkspaceLive.Show.TerminalChrome,
    only: [
      session_attach_id: 1,
      session_tab_detail: 1,
      session_tab_label: 1,
      session_kind_label: 1,
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

  @type workspace_tab :: %{
          id: String.t(),
          dom_id: String.t(),
          kind: atom(),
          label: String.t(),
          detail: String.t(),
          title: String.t(),
          href: String.t() | nil
        }

  @spec session_tabs([SessionInfo.t()]) :: [tab()]
  def session_tabs(infos) when is_list(infos) do
    {tabs, _counters} =
      Enum.map_reduce(infos, %{}, fn info, counters ->
        {ordinal, counters} = next_session_ordinal(info.kind, counters)
        {session_tab(info, ordinal), counters}
      end)

    tabs
  end

  @spec session_tab(SessionInfo.t()) :: tab()
  def session_tab(%SessionInfo{} = info), do: session_tab(info, nil)

  defp session_tab(%SessionInfo{} = info, ordinal) do
    id = session_attach_id(info)

    %{
      id: id,
      dom_id: "active_sessions-" <> id,
      kind: info.kind,
      label: session_tab_label(info),
      detail: session_tab_detail(info, ordinal),
      title: session_tab_title(info),
      tmux_session: info.tmux_session
    }
  end

  @spec workspace_session_tabs([map()], String.t()) :: [workspace_tab()]
  def workspace_session_tabs(summaries, current_workspace_id) when is_list(summaries) do
    summaries
    |> Enum.reject(&(summary_id(&1) == current_workspace_id))
    |> Enum.flat_map(&workspace_summary_tabs/1)
  end

  @spec tmux_inventory_tabs([map()]) :: [workspace_tab()]
  def tmux_inventory_tabs(sessions) when is_list(sessions) do
    Enum.map(sessions, &tmux_inventory_tab/1)
  end

  defp workspace_summary_tabs(summary) do
    summary
    |> sessions_from_summary()
    |> Enum.map(&workspace_session_tab(summary, &1))
  end

  defp workspace_session_tab(summary, session) do
    kind = Map.get(session, :kind) || Map.get(session, "kind")
    session_id = Map.get(session, :id) || Map.get(session, "id") || "unknown"
    workspace_id = summary_id(summary) || "workspace"
    id = workspace_id <> ":" <> session_id

    %{
      id: id,
      dom_id: "workspace_sessions-" <> dom_fragment(id),
      kind: kind,
      label: workspace_session_label(session, kind),
      detail: workspace_session_detail(summary, session),
      title: workspace_session_title(summary, session),
      href: blank_to_nil(Map.get(session, :href) || Map.get(session, "href"))
    }
  end

  defp tmux_inventory_tab(session) do
    id = Map.get(session, :id) || Map.get(session, "id") || "tmux-session"

    %{
      id: id,
      dom_id: "workspace_sessions-" <> dom_fragment(id),
      kind: Map.get(session, :kind) || Map.get(session, "kind") || :shell,
      label: Map.get(session, :label) || Map.get(session, "label") || "tmux",
      detail: Map.get(session, :detail) || Map.get(session, "detail") || "",
      title: Map.get(session, :title) || Map.get(session, "title") || id,
      href: nil
    }
  end

  defp summary_id(summary), do: Map.get(summary, :id) || Map.get(summary, "id")

  defp sessions_from_summary(summary) do
    Map.get(summary, :sessions) || Map.get(summary, "sessions") || []
  end

  defp workspace_session_label(session, kind) do
    label =
      [
        Map.get(session, :cwd_label),
        Map.get(session, "cwd_label"),
        Map.get(session, :label),
        Map.get(session, "label"),
        fallback_session_label(kind)
      ]
      |> Enum.find(&(not blank?(&1)))

    label || "session"
  end

  defp fallback_session_label(:shell), do: "workspace"
  defp fallback_session_label("shell"), do: "workspace"
  defp fallback_session_label(kind), do: session_kind_label(kind)

  defp workspace_session_detail(summary, session) do
    workspace_label =
      Map.get(summary, :path_label) ||
        Map.get(summary, "path_label") ||
        Map.get(summary, :name) ||
        Map.get(summary, "name") ||
        ""

    branch = Map.get(session, :branch) || Map.get(session, "branch")
    agent = Map.get(session, :agent) || Map.get(session, "agent")

    [workspace_label, branch, agent]
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.join(" · ")
  end

  defp workspace_session_title(summary, session) do
    workspace =
      Map.get(summary, :name) ||
        Map.get(summary, "name") ||
        summary_id(summary) ||
        "workspace"

    session_title =
      Map.get(session, :title) ||
        Map.get(session, "title") ||
        Map.get(session, :id) ||
        Map.get(session, "id") ||
        "session"

    workspace <> " - " <> session_title
  end

  defp next_session_ordinal(:shell, counters) do
    ordinal = Map.get(counters, :shell, 1) + 1
    {ordinal, Map.put(counters, :shell, ordinal)}
  end

  defp next_session_ordinal(kind, counters) do
    ordinal = Map.get(counters, kind, 0) + 1
    {ordinal, Map.put(counters, kind, ordinal)}
  end

  defp session_tab_detail(%SessionInfo{kind: :shell} = info, _ordinal),
    do: session_tab_detail(info)

  defp session_tab_detail(%SessionInfo{kind: kind} = info, ordinal)
       when kind in [:execution, :agent] and is_integer(ordinal),
       do: TerminalChrome.session_tab_detail(info, Integer.to_string(ordinal))

  defp session_tab_detail(%SessionInfo{runner_id: runner}, _ordinal) when is_binary(runner),
    do: runner

  defp session_tab_detail(_session, _ordinal), do: ""

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp blank_to_nil(value), do: if(blank?(value), do: nil, else: value)

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
