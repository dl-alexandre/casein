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

  alias DevIDE.Labels
  alias DevIDE.Terminals.Session.Info, as: SessionInfo
  alias DevIdeWeb.WorkspaceLive.Show.TerminalChrome

  import DevIdeWeb.WorkspaceLive.Show.TerminalChrome,
    only: [
      session_attach_id: 1,
      session_tab_detail: 1,
      session_tab_label: 1,
      session_tab_title: 1,
      pane_activity_state: 1,
      pane_picker_detail: 2,
      pane_picker_label: 3,
      agent_label_title: 1,
      pane_picker_title: 2,
      pane_status: 1,
      pane_status_class: 1,
      pane_status_label: 1,
      pane_ui_active?: 2,
      preview_favicon_url: 1,
      window_activity_state: 1,
      window_activity_class: 1,
      window_activity_label: 1,
      window_full_title: 2
    ]

  import DevIdeWeb.WorkspaceLive.Show.UI, only: [dom_fragment: 1]

  @type session_window :: %{
          id: String.t() | nil,
          index: integer() | nil,
          name: String.t(),
          active?: boolean(),
          pane_ids: [String.t()],
          preview_count: non_neg_integer()
        }

  @type tab :: %{
          id: String.t(),
          dom_id: String.t(),
          kind: atom(),
          label: String.t(),
          detail: String.t(),
          title: String.t(),
          tmux_session: String.t() | nil,
          windows: [session_window()],
          window_count: non_neg_integer(),
          pane_ids: [String.t()]
        }

  @type workspace_tab :: %{
          id: String.t(),
          dom_id: String.t(),
          workspace_id: String.t(),
          session_id: String.t(),
          kind: atom(),
          label: String.t(),
          detail: String.t(),
          title: String.t(),
          cwd: String.t() | nil,
          href: String.t() | nil,
          tmux_session: String.t() | nil,
          windows: [session_window()],
          window_count: non_neg_integer(),
          preview_count: non_neg_integer(),
          quiet_count: non_neg_integer(),
          activity_state: :fresh | :recent | :idle,
          activity_class: String.t(),
          activity_label: String.t()
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
    windows = session_windows(info)
    activity_state = session_activity_state(windows)

    %{
      id: id,
      dom_id: "active_sessions-" <> id,
      kind: info.kind,
      label: session_tab_label(info),
      detail: session_tab_detail(info, ordinal),
      title: session_tab_title(info),
      cwd: session_cwd(info),
      tmux_session: info.tmux_session,
      windows: windows,
      window_count: length(windows),
      quiet_count: Enum.count(windows, & &1.quiet?),
      pane_ids: windows |> Enum.flat_map(& &1.pane_ids) |> Enum.uniq(),
      preview_count: 0,
      activity_state: activity_state,
      activity_class: window_activity_class(activity_state),
      activity_label: window_activity_label(activity_state)
    }
  end

  @doc """
  Refreshes the visible cwd-derived fields for a rendered session tab.

  The session directory remains the canonical source for membership, windows,
  and git context. Live tmux topology can be fresher for the active pane cwd,
  so callers use this as an optimistic UI update until the next directory poll.
  """
  @spec update_tmux_session_cwd([tab()], String.t() | nil, String.t() | nil) :: [tab()]
  def update_tmux_session_cwd(tabs, tmux_session, cwd)
      when is_list(tabs) and is_binary(tmux_session) and is_binary(cwd) and cwd != "" do
    Enum.map(tabs, fn
      %{tmux_session: ^tmux_session} = tab -> put_tab_cwd(tab, cwd)
      tab -> tab
    end)
  end

  def update_tmux_session_cwd(tabs, _tmux_session, _cwd) when is_list(tabs), do: tabs

  defp put_tab_cwd(%{cwd: cwd} = tab, cwd), do: tab

  defp put_tab_cwd(tab, cwd) do
    old_cwd = Map.get(tab, :cwd)

    tab
    |> Map.put(:cwd, cwd)
    |> Map.put(:label, cwd_label(cwd, old_cwd, Map.get(tab, :label)))
    |> Map.put(:title, cwd_title(Map.get(tab, :title), old_cwd, cwd))
  end

  defp cwd_label(cwd, old_cwd, old_label) do
    case {old_cwd, old_label} do
      {old_cwd, old_label} when is_binary(old_cwd) and is_binary(old_label) ->
        String.replace(old_label, cwd_label_segment(old_cwd), cwd_label_segment(cwd))

      _ ->
        cwd_label_segment(cwd)
    end
  end

  defp cwd_label_segment(cwd), do: TerminalChrome.short_path(cwd)

  defp cwd_title(title, old_cwd, cwd) when is_binary(title) do
    cond do
      is_binary(old_cwd) and old_cwd != "" and String.contains?(title, old_cwd) ->
        String.replace(title, old_cwd, cwd)

      String.contains?(title, cwd) ->
        title

      true ->
        title <> " · " <> cwd
    end
  end

  defp cwd_title(_title, _old_cwd, cwd), do: cwd

  # tmux flags a session in choose-tree when any window has activity; the
  # session row inherits the freshest window state.
  defp session_activity_state(windows) do
    states = Enum.map(windows, & &1.activity_state)

    cond do
      :fresh in states -> :fresh
      :recent in states -> :recent
      true -> :idle
    end
  end

  defp session_windows(%SessionInfo{metadata: metadata}) when is_map(metadata) do
    activity =
      Map.get(metadata, :window_activity) || Map.get(metadata, "window_activity") || %{}

    window_panes =
      Map.get(metadata, :window_panes) || Map.get(metadata, "window_panes") || %{}

    (Map.get(metadata, :windows) || Map.get(metadata, "windows") || [])
    |> Enum.map(fn window ->
      id = Map.get(window, :id) || Map.get(window, "id")
      activity_state = window_activity_state(%{activity: Map.get(activity, id)})

      %{
        id: id,
        index: Map.get(window, :index) || Map.get(window, "index"),
        name: Map.get(window, :name) || Map.get(window, "name") || "window",
        active?: (Map.get(window, :active) || Map.get(window, "active")) == true,
        quiet?: (Map.get(window, :quiet) || Map.get(window, "quiet")) == true,
        pane_ids: window_pane_ids(window_panes, id),
        preview_count: 0,
        activity_state: activity_state,
        activity_class: window_activity_class(activity_state),
        activity_label: window_activity_label(activity_state)
      }
    end)
    |> Enum.sort_by(& &1.index)
  end

  defp session_windows(_info), do: []

  defp window_pane_ids(window_panes, id) when is_map(window_panes) do
    ids = Map.get(window_panes, id) || Map.get(window_panes, to_string_or_nil(id)) || []
    if is_list(ids), do: ids, else: []
  end

  defp window_pane_ids(_window_panes, _id), do: []

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value), do: to_string(value)

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
    info = session_info_from_summary(summary, session)
    workspace_id = summary_id(summary) || "workspace"
    session_id = session_attach_id(info)
    id = workspace_id <> ":" <> session_id
    base = session_tab(info)

    base
    |> put_preview_counts(preview_pane_ids(session))
    |> Map.merge(%{
      id: id,
      dom_id: "workspace_sessions-" <> dom_fragment(id),
      workspace_id: workspace_id,
      session_id: session_id,
      label: cross_workspace_label(session, info, summary),
      title: workspace_cross_title(summary, info),
      href: blank_to_nil(Map.get(session, :href) || Map.get(session, "href"))
    })
  end

  defp session_info_from_summary(_summary, %SessionInfo{} = info), do: info

  defp session_info_from_summary(summary, session) when is_map(session) do
    workspace_id = summary_id(summary) || "workspace"
    sid = Map.get(session, :id) || Map.get(session, "id") || "unknown"
    kind = Map.get(session, :kind) || Map.get(session, "kind") || :shell
    metadata = session_metadata_from_map(session)
    tmux_session = Map.get(session, :tmux_session) || Map.get(session, "tmux_session")

    info =
      case kind do
        :agent ->
          SessionInfo.new_agent(sid, workspace_id: workspace_id, metadata: metadata)

        _ ->
          SessionInfo.new_shell(workspace_id, sid, metadata: metadata)
      end

    if is_binary(tmux_session) and tmux_session != "" do
      %{info | tmux_session: tmux_session}
    else
      info
    end
  end

  defp session_metadata_from_map(session) do
    base =
      case Map.get(session, :metadata) || Map.get(session, "metadata") do
        metadata when is_map(metadata) -> metadata
        _ -> %{}
      end

    base
    |> put_metadata_field(session, :cwd)
    |> put_metadata_field(session, "cwd")
    |> put_metadata_field(session, :git_toplevel)
    |> put_metadata_field(session, "git_toplevel")
    |> put_metadata_field(session, :git_branch, :branch)
    |> put_metadata_field(session, "git_branch", "branch")
    |> put_metadata_field(session, :agent)
    |> put_metadata_field(session, "agent")
    |> put_metadata_field(session, :windows)
    |> put_metadata_field(session, "windows")
    |> put_metadata_field(session, :window_activity)
    |> put_metadata_field(session, "window_activity")
    |> put_metadata_field(session, :window_panes)
    |> put_metadata_field(session, "window_panes")
  end

  defp preview_pane_ids(session) when is_map(session) do
    ids = Map.get(session, :preview_pane_ids) || Map.get(session, "preview_pane_ids") || []
    if is_list(ids), do: ids, else: []
  end

  defp put_preview_counts(tab, []), do: tab

  defp put_preview_counts(tab, preview_pane_ids) when is_list(preview_pane_ids) do
    preview_pane_ids = MapSet.new(preview_pane_ids)

    windows =
      Enum.map(tab.windows, fn window ->
        count = Enum.count(window.pane_ids, &MapSet.member?(preview_pane_ids, &1))
        Map.put(window, :preview_count, count)
      end)

    tab
    |> Map.put(:windows, windows)
    |> Map.put(:preview_count, Enum.sum(Enum.map(windows, & &1.preview_count)))
  end

  defp session_cwd(%SessionInfo{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, :cwd) || Map.get(metadata, "cwd")
  end

  defp session_cwd(_), do: nil

  defp put_metadata_field(metadata, session, source_key, dest_key \\ nil) do
    dest_key = dest_key || source_key

    case Map.get(session, source_key) do
      value when value in [nil, ""] -> metadata
      value -> Map.put(metadata, dest_key, value)
    end
  end

  defp cross_workspace_label(session, %SessionInfo{} = info, summary) do
    context_label = session_tab_label(info)

    if context_label in ["workspace", "Shell"] do
      [
        Map.get(session, :cwd_label),
        Map.get(session, "cwd_label"),
        Map.get(session, :label),
        Map.get(session, "label"),
        summary_path_basename(summary)
      ]
      |> Enum.find(&(is_binary(&1) and &1 != "")) || context_label
    else
      context_label
    end
  end

  defp summary_path_basename(summary) do
    case Map.get(summary, :path_label) || Map.get(summary, "path_label") do
      label when is_binary(label) and label != "" ->
        label |> String.split("/") |> List.last()

      _ ->
        nil
    end
  end

  defp workspace_cross_title(summary, %SessionInfo{} = info) do
    workspace =
      Map.get(summary, :name) ||
        Map.get(summary, "name") ||
        summary_id(summary) ||
        "workspace"

    workspace <> " – " <> session_tab_title(info)
  end

  defp tmux_inventory_tab(session) do
    id = Map.get(session, :id) || Map.get(session, "id") || "tmux-session"

    %{
      id: id,
      dom_id: "workspace_sessions-" <> dom_fragment(id),
      workspace_id: "",
      session_id: id,
      kind: Map.get(session, :kind) || Map.get(session, "kind") || :shell,
      label: Map.get(session, :label) || Map.get(session, "label") || "tmux",
      detail: Map.get(session, :detail) || Map.get(session, "detail") || "",
      title: Map.get(session, :title) || Map.get(session, "title") || id,
      href: nil,
      tmux_session: nil,
      windows: [],
      window_count: 0,
      pane_ids: [],
      preview_count: 0,
      quiet_count: 0,
      activity_state: :idle,
      activity_class: window_activity_class(:idle),
      activity_label: window_activity_label(:idle)
    }
  end

  defp summary_id(summary), do: Map.get(summary, :id) || Map.get(summary, "id")

  defp sessions_from_summary(summary) do
    Map.get(summary, :sessions) || Map.get(summary, "sessions") || []
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

  defp session_tab_detail(%SessionInfo{kind: :agent} = info, ordinal)
       when is_integer(ordinal),
       do: TerminalChrome.session_tab_detail(info, Integer.to_string(ordinal))

  defp session_tab_detail(%SessionInfo{runner_id: runner}, _ordinal) when is_binary(runner),
    do: runner

  defp session_tab_detail(_session, _ordinal), do: ""

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp blank_to_nil(value), do: if(blank?(value), do: nil, else: value)

  @type pane_tab :: %{
          id: String.t(),
          dom_frag: String.t(),
          index: integer() | nil,
          preview?: boolean(),
          label: String.t(),
          detail: String.t(),
          title: String.t(),
          favicon_url: String.t() | nil,
          active?: boolean(),
          activity_state: :fresh | :recent | :idle,
          activity_class: String.t(),
          activity_label: String.t()
        }

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
          full_title: String.t(),
          panes: [pane_tab()],
          pane_count: non_neg_integer()
        }

  @doc """
  Maps raw tmux topology windows (as produced by `TmuxTopology.snapshot/2`)
  to render-ready window tabs. Activity state is baked in because window
  data only changes via topology updates, which rebuild this list anyway.
  """
  @spec window_tabs([map()], String.t() | nil, map(), keyword()) :: [window_tab()]
  def window_tabs(windows, highlight_pane_id \\ nil, preview_panes \\ %{}, opts \\ [])
      when is_list(windows) do
    Enum.map(windows, &window_tab(&1, highlight_pane_id, preview_panes, opts))
  end

  def window_tab(window, highlight_pane_id \\ nil, preview_panes \\ %{}, opts \\ []) do
    activity_state = window_activity_state(window)
    preview_count = window_preview_count(window, preview_panes)
    panes = pane_tabs(window, preview_panes, highlight_pane_id, opts)

    %{
      id: window.id,
      dom_frag: dom_fragment(window.id),
      index: window.index,
      name: window.name,
      active?: window.active,
      quiet?: DevIDE.Terminals.Activity.agent_window_quiet?(window),
      activity_state: activity_state,
      activity_class: window_activity_class(activity_state),
      activity_label: window_activity_label(activity_state),
      preview_count: preview_count,
      preview?: preview_count > 0,
      command: window.current_command,
      full_title: window_full_title(window, highlight_pane_id),
      panes: panes,
      pane_count: length(panes)
    }
  end

  defp pane_tabs(window, preview_panes, highlight_pane_id, opts) do
    window
    |> Map.get(:pane_list, [])
    |> Enum.sort_by(&(Map.get(&1, :index) || Map.get(&1, "index") || 0))
    |> Enum.map(&pane_tab(&1, preview_panes, highlight_pane_id, opts))
  end

  defp pane_tab(pane, preview_panes, highlight_pane_id, opts) do
    pane_id = Map.get(pane, :id) || Map.get(pane, "id")
    preview = Map.get(preview_panes, pane_id)
    preview? = is_map(preview)
    status = pane_status(pane)
    activity_state = pane_activity_state(pane)
    tmux_session = Keyword.get(opts, :tmux_session)
    pane_labels = Keyword.get(opts, :pane_labels, %{})
    overlay = pane_label_entry(pane_labels, tmux_session, pane_id)

    %{
      id: pane_id,
      dom_frag: dom_fragment(pane_id),
      index: Map.get(pane, :index) || Map.get(pane, "index"),
      preview?: preview?,
      label: pane_picker_label(pane, preview, overlay_text(overlay)),
      detail: pane_picker_detail(pane, preview),
      title: pane_picker_title(pane, preview),
      agent_label?: is_binary(overlay_text(overlay)),
      agent_label_source: overlay && overlay.source,
      agent_label_title: agent_label_title(overlay),
      favicon_url: if(preview?, do: preview_favicon_url(preview), else: nil),
      active?: pane_ui_active?(pane, highlight_pane_id),
      activity_state: activity_state,
      activity_class: pane_status_class(status),
      activity_label: pane_status_label(status)
    }
  end

  defp window_preview_count(window, preview_panes) when is_map(preview_panes) do
    preview_ids =
      preview_panes
      |> Map.keys()
      |> MapSet.new()

    window
    |> Map.get(:pane_list, [])
    |> Enum.count(fn pane ->
      MapSet.member?(preview_ids, Map.get(pane, :id) || Map.get(pane, "id"))
    end)
  end

  defp window_preview_count(_window, _preview_panes), do: 0

  defp pane_label_entry(pane_labels, tmux_session, pane_id)
       when is_map(pane_labels) and is_binary(tmux_session) and is_binary(pane_id) do
    Map.get(pane_labels, Labels.key(tmux_session, pane_id))
  end

  defp pane_label_entry(_pane_labels, _tmux_session, _pane_id), do: nil

  defp overlay_text(%{label: label}) when is_binary(label) and label != "", do: label
  defp overlay_text(_), do: nil
end
