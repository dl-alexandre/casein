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

  alias DevIDE.Attention.Policy, as: AttentionPolicy
  alias DevIDE.Labels
  alias DevIDE.Terminals
  alias DevIDE.Terminals.AgentState
  alias DevIDE.Terminals.PaneState
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
          attention: String.t(),
          unseen_quiet?: boolean(),
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
          quiet_count: non_neg_integer(),
          unseen_quiet_count: non_neg_integer(),
          attention: String.t(),
          preview_count: non_neg_integer(),
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
          unseen_quiet_count: non_neg_integer(),
          attention: String.t(),
          activity_state: :fresh | :recent | :idle,
          activity_class: String.t(),
          activity_label: String.t()
        }

  @spec session_tabs([map()], keyword()) :: [tab()]
  def session_tabs(infos, opts \\ []) when is_list(infos) do
    {tabs, _counters} =
      Enum.map_reduce(infos, %{}, fn info, counters ->
        {ordinal, counters} = next_session_ordinal(info.kind, counters)
        {session_tab(info, ordinal, opts), counters}
      end)

    tabs
  end

  @spec session_tab(map()) :: tab()
  def session_tab(info) when is_map(info), do: session_tab(info, nil, [])

  defp session_tab(info, ordinal, opts) when is_map(info) do
    id = session_attach_id(info)
    windows = session_windows(info, opts)
    activity_state = session_activity_state(windows)
    quiet_count = Enum.count(windows, & &1.quiet?)
    unseen_quiet_count = Enum.count(windows, & &1.unseen_quiet?)

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
      quiet_count: quiet_count,
      unseen_quiet_count: unseen_quiet_count,
      attention: session_quiet_attention(quiet_count, unseen_quiet_count),
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

  defp session_windows(%{metadata: metadata} = info, opts) when is_map(metadata) do
    activity =
      Map.get(metadata, :window_activity) || Map.get(metadata, "window_activity") || %{}

    agent_messages =
      Map.get(metadata, :agent_state_messages) || Map.get(metadata, "agent_state_messages") || %{}

    window_panes =
      Map.get(metadata, :window_panes) || Map.get(metadata, "window_panes") || %{}

    (Map.get(metadata, :windows) || Map.get(metadata, "windows") || [])
    |> Enum.map(fn window ->
      id = Map.get(window, :id) || Map.get(window, "id")
      name = Map.get(window, :name) || Map.get(window, "name") || "window"

      pane_state =
        normalized_pane_state(Map.get(window, :pane_state) || Map.get(window, "pane_state"))

      agent_state =
        normalized_agent_state(Map.get(window, :agent_state) || Map.get(window, "agent_state"))

      agent_message = blank_to_nil(Map.get(agent_messages, id))

      task_summary =
        blank_to_nil(Map.get(window, :task_summary) || Map.get(window, "task_summary"))

      manual_name? =
        (Map.get(window, :manual_name) || Map.get(window, "manual_name")) == true

      activity_state =
        effective_window_activity_state(
          window_activity_state(%{activity: Map.get(activity, id)}),
          pane_state
        )

      quiet? = (Map.get(window, :quiet) || Map.get(window, "quiet")) == true
      unseen_quiet? = quiet? and unseen_quiet_window?(opts, session_attach_id(info), id)

      {activity_class, activity_label} =
        apply_agent_state(
          effective_window_activity_class(activity_state, pane_state),
          effective_window_activity_label(activity_state, pane_state),
          agent_state,
          agent_message
        )

      %{
        id: id,
        index: Map.get(window, :index) || Map.get(window, "index"),
        name: name,
        display_name: window_display_name(manual_name?, task_summary, name),
        active?: (Map.get(window, :active) || Map.get(window, "active")) == true,
        quiet?: quiet?,
        unseen_quiet?: unseen_quiet?,
        attention: quiet_attention(quiet?, unseen_quiet?),
        quiet_label: window_quiet_label(pane_state),
        pane_state: pane_state,
        agent_state: agent_state,
        agent_state_message: agent_message,
        task_summary: task_summary,
        pane_ids: window_pane_ids(window_panes, id),
        preview_count: 0,
        activity_state: activity_state,
        activity_class: activity_class,
        activity_label: activity_label
      }
    end)
    |> Enum.sort_by(& &1.index)
  end

  defp session_windows(_info, _opts), do: []

  defp window_pane_ids(window_panes, id) when is_map(window_panes) do
    ids = Map.get(window_panes, id) || Map.get(window_panes, to_string_or_nil(id)) || []
    if is_list(ids), do: ids, else: []
  end

  defp window_pane_ids(_window_panes, _id), do: []

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value), do: to_string(value)

  @doc "Cycles sidebar sort mode: recency → name → liveness → recency."
  @spec cycle_sort_mode(atom()) :: atom()
  def cycle_sort_mode(:recency), do: :name
  def cycle_sort_mode(:name), do: :liveness
  def cycle_sort_mode(:liveness), do: :recency
  def cycle_sort_mode(_), do: :name

  @spec sort_mode_label(atom()) :: String.t()
  def sort_mode_label(:recency), do: "Recent"
  def sort_mode_label(:name), do: "Name"
  def sort_mode_label(:liveness), do: "Live"
  def sort_mode_label(_), do: "Recent"

  @doc """
  Sorts workspace summaries for the SESSIONS sidebar. The current workspace
  stays pinned first regardless of mode.
  """
  @spec sort_workspace_summaries_for_sidebar([map()], atom(), String.t()) :: [map()]
  def sort_workspace_summaries_for_sidebar(summaries, mode, current_workspace_id)
      when is_list(summaries) and is_binary(current_workspace_id) do
    {current, rest} = Enum.split_with(summaries, &(summary_id(&1) == current_workspace_id))
    current ++ sort_workspace_summaries_list(rest, mode)
  end

  defp sort_workspace_summaries_list(summaries, :recency), do: summaries

  defp sort_workspace_summaries_list(summaries, :name) do
    Enum.sort_by(summaries, &String.downcase(summary_workspace_label(&1)))
  end

  defp sort_workspace_summaries_list(summaries, :liveness) do
    Enum.sort_by(summaries, fn summary ->
      {if(workspace_summary_live?(summary), do: 0, else: 1),
       String.downcase(summary_workspace_label(summary))}
    end)
  end

  @doc "Sorts session children inside SESSIONS sidebar tree nodes."
  @spec sort_sessions_in_tree([workspace_tree_node()], atom()) :: [workspace_tree_node()]
  def sort_sessions_in_tree(nodes, mode) when is_list(nodes) do
    Enum.map(nodes, fn
      %{sessions: sessions} = node when is_list(sessions) ->
        Map.put(node, :sessions, sort_session_tabs(sessions, mode))

      node ->
        node
    end)
  end

  @doc "Sorts session tab view-models for sidebar display."
  @spec sort_session_tabs([tab()], atom()) :: [tab()]
  def sort_session_tabs(tabs, mode) when is_list(tabs) do
    case mode do
      :name ->
        Enum.sort_by(tabs, &String.downcase(&1.label))

      :liveness ->
        Enum.sort_by(
          tabs,
          &{activity_liveness_rank(&1.activity_state), String.downcase(&1.label)}
        )

      _ ->
        tabs
    end
  end

  @doc "Sorts WINDOWS sidebar tree nodes."
  @spec sort_window_tree([window_tree_node()], atom()) :: [window_tree_node()]
  def sort_window_tree(nodes, mode) when is_list(nodes), do: sort_window_nodes(nodes, mode)

  defp sort_window_nodes(nodes, :recency) do
    Enum.sort_by(nodes, fn window ->
      {window_recency_rank(window), activity_liveness_rank(window.activity_state),
       String.downcase(window_label(window))}
    end)
  end

  defp sort_window_nodes(nodes, :name) do
    Enum.sort_by(nodes, &String.downcase(window_label(&1)))
  end

  defp sort_window_nodes(nodes, :liveness) do
    Enum.sort_by(nodes, fn window ->
      {if(window.active?, do: 0, else: 1), activity_liveness_rank(window.activity_state),
       String.downcase(window_label(window))}
    end)
  end

  defp window_label(%{display_name: name}) when is_binary(name) and name != "", do: name
  defp window_label(%{name: name}) when is_binary(name), do: name
  defp window_label(_), do: ""

  defp window_recency_rank(%{active?: true}), do: 0
  defp window_recency_rank(%{index: index}) when is_integer(index), do: 1 + index
  defp window_recency_rank(_), do: 999

  defp activity_liveness_rank(:fresh), do: 0
  defp activity_liveness_rank(:recent), do: 1
  defp activity_liveness_rank(:idle), do: 2
  defp activity_liveness_rank(_), do: 3

  @type workspace_tree_node :: %{
          id: String.t(),
          dom_id: String.t(),
          workspace_id: String.t(),
          label: String.t(),
          detail: String.t(),
          title: String.t(),
          current?: boolean(),
          live?: boolean(),
          session_count: non_neg_integer(),
          expanded?: boolean(),
          flat_session?: boolean(),
          session: tab() | workspace_tab() | nil,
          sessions: [tab() | workspace_tab()] | nil
        }

  @doc """
  Builds the SESSIONS sidebar tree: workspace upper tier, session children when
  expanded. Collapsed rows carry only cheap summary badges; callers must not
  enumerate sessions until `expanded?: true`. A workspace with exactly one
  attachable session collapses to a single flat row (`flat_session?: true`).
  """
  @spec workspace_session_tree([map()], String.t(), keyword()) :: [workspace_tree_node()]
  def workspace_session_tree(summaries, current_workspace_id, opts \\ [])
      when is_list(summaries) do
    expanded = Keyword.get(opts, :expanded_workspaces, MapSet.new())
    current_session_tabs = Keyword.get(opts, :current_session_tabs, [])
    sidebar_ws_sessions = Keyword.get(opts, :sidebar_ws_sessions, %{})

    summaries
    |> order_workspace_summaries(current_workspace_id)
    |> Enum.map(
      &workspace_tree_node(
        &1,
        current_workspace_id,
        expanded,
        current_session_tabs,
        sidebar_ws_sessions
      )
    )
  end

  defp order_workspace_summaries(summaries, current_workspace_id) do
    Enum.sort_by(summaries, fn summary ->
      if summary_id(summary) == current_workspace_id, do: 0, else: 1
    end)
  end

  defp workspace_tree_node(summary, current_workspace_id, expanded, current_tabs, sidebar_ws) do
    workspace_id = summary_id(summary) || "workspace"
    current? = workspace_id == current_workspace_id
    expanded? = MapSet.member?(expanded, workspace_id)
    session_count = summary_session_count(summary)
    live? = workspace_summary_live?(summary)

    sessions =
      cond do
        current? and is_list(current_tabs) ->
          Enum.map(current_tabs, &Map.put(&1, :workspace_id, workspace_id))

        expanded? ->
          sidebar_ws
          |> Map.get(workspace_id, [])
          |> Enum.map(&Map.put(&1, :workspace_id, workspace_id))

        true ->
          nil
      end

    flat_session? = is_list(sessions) and length(sessions) == 1

    %{
      id: workspace_id,
      dom_id: "sidebar-ws-" <> dom_fragment(workspace_id),
      workspace_id: workspace_id,
      label: summary_workspace_label(summary),
      detail: summary_workspace_detail(summary),
      title: summary_workspace_title(summary),
      current?: current?,
      live?: live?,
      session_count: session_count,
      expanded?: expanded? and not flat_session?,
      flat_session?: flat_session?,
      session: if(flat_session?, do: List.first(sessions), else: nil),
      sessions: if(flat_session?, do: nil, else: sessions)
    }
  end

  defp summary_workspace_label(summary) do
    Map.get(summary, :name) || Map.get(summary, "name") || summary_id(summary) || "workspace"
  end

  defp summary_workspace_detail(summary) do
    branch = Map.get(summary, :branch) || Map.get(summary, "branch")
    path_label = Map.get(summary, :path_label) || Map.get(summary, "path_label")

    cond do
      is_binary(branch) and branch != "" -> branch
      is_binary(path_label) and path_label != "" -> path_label
      true -> ""
    end
  end

  defp summary_workspace_title(summary) do
    label = summary_workspace_label(summary)
    detail = summary_workspace_detail(summary)

    if detail != "" and detail != label do
      label <> " · " <> detail
    else
      label
    end
  end

  defp summary_session_count(summary) do
    count = Map.get(summary, :session_count) || Map.get(summary, "session_count")

    case count do
      n when is_integer(n) and n >= 0 -> n
      _ -> length(sessions_from_summary(summary))
    end
  end

  @spec workspace_session_tabs([map()], String.t()) :: [workspace_tab()]
  def workspace_session_tabs(summaries, current_workspace_id) when is_list(summaries) do
    summaries
    |> Enum.reject(&(summary_id(&1) == current_workspace_id))
    # Only surface other workspaces you can actually switch into. Dead
    # `agent-*-adhoc-*` worktrees left on disk have no live tmux session, so
    # they resolve to live? == false and drop out of the cross-workspace list
    # instead of piling up one meaningless row per past agent launch.
    |> Enum.filter(&workspace_summary_live?/1)
    |> Enum.flat_map(&workspace_summary_tabs/1)
  end

  defp workspace_summary_live?(summary) do
    Map.get(summary, :live?, Map.get(summary, "live?", true)) != false
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

  defp session_info_from_summary(summary, session) when is_map(session) do
    if Terminals.session_info?(session) do
      session
    else
      session_info_from_summary_map(summary, session)
    end
  end

  defp session_info_from_summary_map(summary, session) do
    workspace_id = summary_id(summary) || "workspace"
    sid = Map.get(session, :id) || Map.get(session, "id") || "unknown"
    kind = Map.get(session, :kind) || Map.get(session, "kind") || :shell
    metadata = session_metadata_from_map(session)
    tmux_session = Map.get(session, :tmux_session) || Map.get(session, "tmux_session")

    info =
      case kind do
        :agent ->
          Terminals.new_agent(sid, workspace_id: workspace_id, metadata: metadata)

        _ ->
          Terminals.new_shell(workspace_id, sid, metadata: metadata)
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

  defp session_cwd(%{metadata: metadata}) when is_map(metadata) do
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

  defp cross_workspace_label(session, info, summary) when is_map(info) do
    context_label = session_tab_label(info)
    agent_title = cross_workspace_agent_title(session)

    cond do
      # An explicit operator/agent alias is deliberate naming — always keep it.
      session_alias?(session) ->
        context_label

      # For an agent worktree the context label is just its flattened dir name
      # (`agent-<tool>-adhoc-<stamp>`); the task title is what it is actually
      # doing, which is what the operator wants to recognise it by.
      agent_session?(session) and is_binary(agent_title) ->
        agent_title

      # Generic label with no better signal: fall through cwd → path basename.
      context_label in ["workspace", "Shell", "Agent"] ->
        [
          agent_title,
          Map.get(session, :cwd_label),
          Map.get(session, "cwd_label"),
          Map.get(session, :label),
          Map.get(session, "label"),
          summary_path_basename(summary)
        ]
        |> Enum.find(&(is_binary(&1) and &1 != "")) || context_label

      true ->
        context_label
    end
  end

  defp cross_workspace_agent_title(session) do
    case Map.get(session, :agent_title) || Map.get(session, "agent_title") do
      title when is_binary(title) ->
        case String.trim(title) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp agent_session?(session) do
    (Map.get(session, :kind) || Map.get(session, "kind")) == :agent
  end

  defp session_alias?(session) do
    metadata = Map.get(session, :metadata) || Map.get(session, "metadata") || %{}
    value = Map.get(metadata, :session_alias) || Map.get(metadata, "session_alias")
    is_binary(value) and String.trim(value) != ""
  end

  defp summary_path_basename(summary) do
    case Map.get(summary, :path_label) || Map.get(summary, "path_label") do
      label when is_binary(label) and label != "" ->
        label |> String.split("/") |> List.last()

      _ ->
        nil
    end
  end

  defp workspace_cross_title(summary, info) when is_map(info) do
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

  defp session_tab_detail(%{kind: :shell} = info, _ordinal),
    do: session_tab_detail(info)

  defp session_tab_detail(%{kind: :agent} = info, ordinal)
       when is_integer(ordinal),
       do: TerminalChrome.session_tab_detail(info, Integer.to_string(ordinal))

  defp session_tab_detail(%{runner_id: runner}, _ordinal) when is_binary(runner),
    do: runner

  defp session_tab_detail(_session, _ordinal), do: ""

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp blank_to_nil(value), do: if(blank?(value), do: nil, else: value)

  defp normalized_pane_state(state) when state in [:working, :ready, :unknown], do: state
  defp normalized_pane_state("working"), do: :working
  defp normalized_pane_state("ready"), do: :ready
  defp normalized_pane_state("unknown"), do: :unknown
  defp normalized_pane_state(_state), do: :unknown

  defp normalized_agent_state(state) when state in [:working, :blocked, :done, :idle], do: state
  defp normalized_agent_state("working"), do: :working
  defp normalized_agent_state("blocked"), do: :blocked
  defp normalized_agent_state("done"), do: :done
  defp normalized_agent_state("idle"), do: :idle
  defp normalized_agent_state(_state), do: nil

  # When an explicit semantic state is present it drives the window's activity
  # dot and tooltip: `blocked` is loud, `done`/`idle` calm, `working` matches the
  # existing working treatment.
  defp apply_agent_state(class, label, state, _message) when state in [nil, :unknown],
    do: {class, label}

  defp apply_agent_state(_class, _label, state, message),
    do: {agent_state_class(state), agent_state_label(state, message)}

  defp present_agent_state(state) when state in [:working, :blocked, :done, :idle], do: state
  defp present_agent_state(_state), do: nil

  defp agent_state_class(:blocked), do: "bg-rose-500 shadow-[0_0_0_3px_rgba(244,63,94,0.25)]"
  defp agent_state_class(:working), do: window_activity_class(:fresh)
  defp agent_state_class(:done), do: "bg-sky-400"
  defp agent_state_class(:idle), do: window_activity_class(:idle)

  defp agent_state_label(:blocked, message),
    do: "Agent blocked: " <> (blank_to_nil(message) || "needs input")

  defp agent_state_label(:working, message) do
    case blank_to_nil(message) do
      nil -> "Agent pane working"
      detail -> "Agent working — " <> detail
    end
  end

  defp agent_state_label(:done, _message), do: "Agent done"
  defp agent_state_label(:idle, _message), do: "Agent idle"

  defp resolve_topology_agent_state(window, pane_state, opts) do
    reports = Keyword.get_lazy(opts, :agent_reports, fn -> topology_agent_reports(opts) end)

    entry =
      case PaneState.agent_or_active_pane(window) do
        nil -> nil
        pane -> Map.get(reports, PaneState.map_get(pane, :id))
      end

    AgentState.resolve_for_display(entry, pane_state)
  end

  defp topology_agent_reports(opts) do
    case Keyword.get(opts, :tmux_session) do
      session when is_binary(session) and session != "" -> AgentState.for_session(session)
      _ -> %{}
    end
  end

  defp effective_window_activity_state(_activity_state, :working), do: :fresh
  defp effective_window_activity_state(activity_state, _state), do: activity_state

  defp effective_window_activity_class(_activity_state, :working),
    do: window_activity_class(:fresh)

  defp effective_window_activity_class(activity_state, _state),
    do: window_activity_class(activity_state)

  defp effective_window_activity_label(_activity_state, :working), do: "Agent pane working"

  defp effective_window_activity_label(activity_state, _state),
    do: window_activity_label(activity_state)

  defp window_quiet_label(:ready), do: "Agent pane ready or awaiting input"
  defp window_quiet_label(_state), do: "Agent pane quiet; likely finished or awaiting input"

  defp quiet_attention(_quiet?, true), do: "unseen"

  defp quiet_attention(quiet?, false) do
    %{quiet?: quiet?}
    |> AttentionPolicy.quiet_agent_window()
    |> AttentionPolicy.reaction_label()
  end

  defp session_quiet_attention(_quiet_count, unseen_quiet_count) when unseen_quiet_count > 0,
    do: "unseen"

  defp session_quiet_attention(quiet_count, _unseen_quiet_count) when quiet_count > 0,
    do: "inline"

  defp session_quiet_attention(_quiet_count, _unseen_quiet_count), do: "nothing"

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
          attention: String.t(),
          activity_state: :fresh | :recent | :idle,
          activity_class: String.t(),
          activity_label: String.t(),
          command: String.t() | nil,
          full_title: String.t(),
          panes: [pane_tab()],
          pane_count: non_neg_integer()
        }

  @type window_tree_node :: %{
          optional(atom()) => term(),
          dom_id: String.t(),
          flat_window?: boolean(),
          expanded?: boolean(),
          pane: pane_tab() | nil,
          panes: [pane_tab()] | nil
        }

  @doc """
  Builds the WINDOWS sidebar tree: window upper tier, pane children when
  expanded. A window with exactly one pane collapses to a single flat row
  (`flat_window?: true`) with no pane child tier.
  """
  @spec window_tree([window_tab()], keyword()) :: [window_tree_node()]
  def window_tree(windows, opts \\ []) when is_list(windows) do
    expanded = Keyword.get(opts, :expanded_windows, MapSet.new())

    Enum.map(windows, &window_tree_node(&1, expanded))
  end

  defp window_tree_node(window, expanded) do
    panes = Map.get(window, :panes, [])
    pane_count = Map.get(window, :pane_count, length(panes))
    flat_window? = pane_count <= 1
    window_id = window.id
    expanded? = MapSet.member?(expanded, window_id) and not flat_window?

    window
    |> Map.put(:dom_id, "sidebar-window-" <> window.dom_frag)
    |> Map.put(:flat_window?, flat_window?)
    |> Map.put(:expanded?, expanded?)
    |> Map.put(:pane, if(flat_window?, do: List.first(panes), else: nil))
    |> Map.put(:panes, window_tree_panes(flat_window?, expanded?, panes))
  end

  defp window_tree_panes(true, _expanded?, _panes), do: nil
  defp window_tree_panes(false, _expanded?, panes), do: panes

  @doc """
  Maps raw tmux topology windows (as produced by `TmuxTopology.snapshot/2`)
  to render-ready window tabs. Activity state is baked in because window
  data only changes via topology updates, which rebuild this list anyway.
  """
  @spec window_tabs([map()], String.t() | nil, map(), keyword()) :: [window_tab()]
  def window_tabs(windows, highlight_pane_id \\ nil, preview_panes \\ %{}, opts \\ [])
      when is_list(windows) do
    opts = Keyword.put_new_lazy(opts, :agent_reports, fn -> topology_agent_reports(opts) end)
    Enum.map(windows, &window_tab(&1, highlight_pane_id, preview_panes, opts))
  end

  def window_tab(window, highlight_pane_id \\ nil, preview_panes \\ %{}, opts \\ []) do
    pane_state = PaneState.window_state(window)
    {resolved_agent_state, agent_message} = resolve_topology_agent_state(window, pane_state, opts)
    agent_state = present_agent_state(resolved_agent_state)
    task_summary = PaneState.window_task_summary(window)
    activity_state = effective_window_activity_state(window_activity_state(window), pane_state)
    preview_count = window_preview_count(window, preview_panes)
    panes = pane_tabs(window, preview_panes, highlight_pane_id, opts)
    quiet? = DevIDE.Terminals.agent_window_quiet?(window)

    unseen_quiet? =
      quiet? and unseen_quiet_window?(opts, Keyword.get(opts, :session_id), window.id)

    attention = quiet_attention(quiet?, unseen_quiet?)
    name = window.name
    manual_name? = Map.get(window, :manual_name) == true

    {activity_class, activity_label} =
      apply_agent_state(
        effective_window_activity_class(activity_state, pane_state),
        effective_window_activity_label(activity_state, pane_state),
        agent_state,
        agent_message
      )

    %{
      id: window.id,
      dom_frag: dom_fragment(window.id),
      index: window.index,
      name: name,
      display_name: window_display_name(manual_name?, task_summary, name),
      active?: window.active,
      quiet?: quiet?,
      unseen_quiet?: unseen_quiet?,
      attention: attention,
      quiet_label: window_quiet_label(pane_state),
      pane_state: pane_state,
      agent_state: agent_state,
      agent_state_message: agent_message,
      task_summary: task_summary,
      activity_state: activity_state,
      activity_class: activity_class,
      activity_label: activity_label,
      preview_count: preview_count,
      preview?: preview_count > 0,
      command: window.current_command,
      full_title: full_window_title(window, highlight_pane_id, task_summary),
      panes: panes,
      pane_count: length(panes)
    }
  end

  defp unseen_quiet_window?(opts, session_id, window_id)
       when is_binary(session_id) and is_binary(window_id) do
    opts
    |> Keyword.get(:unseen_quiet_window_ids)
    |> normalize_unseen_quiet_window_ids()
    |> MapSet.member?({session_id, window_id})
  end

  defp unseen_quiet_window?(_opts, _session_id, _window_id), do: false

  defp normalize_unseen_quiet_window_ids(%MapSet{} = ids), do: ids
  defp normalize_unseen_quiet_window_ids(ids) when is_list(ids), do: MapSet.new(ids)
  defp normalize_unseen_quiet_window_ids(_ids), do: MapSet.new()

  # A deliberately named window (tmux automatic-rename off — the user renamed
  # it, or it was created with an explicit name) keeps that name as its label;
  # live pane-title task summaries only label auto-named windows. The summary
  # still reaches the hover title via full_window_title/3.
  defp window_display_name(true = _manual_name?, _task_summary, name), do: name
  defp window_display_name(_manual_name?, task_summary, name), do: task_summary || name

  defp full_window_title(window, highlight_pane_id, task_summary) do
    title = window_full_title(window, highlight_pane_id)

    case blank_to_nil(task_summary) do
      nil -> title
      ^title -> title
      summary -> summary <> " · " <> title
    end
  end

  defp pane_tabs(window, preview_panes, highlight_pane_id, opts) do
    window
    |> Map.get(:pane_list, [])
    |> Enum.sort_by(&(Map.get(&1, :index) || Map.get(&1, "index") || 0))
    |> Enum.map(&pane_tab(&1, preview_panes, highlight_pane_id, opts))
  end

  defp pane_tab(pane, preview_panes, highlight_pane_id, opts) do
    pane = PaneState.enrich_pane(pane)
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
      beside_agent_preview?: beside_agent_preview?(preview),
      beside_agent_preview_title: beside_agent_preview_title(preview),
      pane_state: Map.get(pane, :pane_state),
      task_summary: Map.get(pane, :task_summary),
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

  defp beside_agent_preview?(%{placement: "beside_agent"}), do: true
  defp beside_agent_preview?(_), do: false

  defp beside_agent_preview_title(%{anchor_pane_id: pane_id}) when is_binary(pane_id) do
    "Preview opened beside agent pane " <> pane_id
  end

  defp beside_agent_preview_title(_), do: "Preview opened beside agent pane"
end
