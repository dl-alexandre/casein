defmodule DevIdeWeb.WorkspaceLive.Dashboard do
  @moduledoc """
  Filesystem-shaped landing page at `/` (path-first navigation Stage 3).

  Renders the path root as a directory browser: every child directory is a row,
  and rows whose directory is a known workspace are enriched with live session
  deep links, agent-status badges, start/stop, and history — absorbing the
  `/workspaces` picker, which now redirects here. `?dir=` browses subdirectories
  (validated through PathSafety; never escapes the root).

  Visibility follows deployment mode: trusted LAN sees everything; forward-auth
  viewers see only their own directories (name matches their identity) plus
  directories holding workspaces they can access, with the admin toggle
  revealing all users.
  """

  use DevIdeWeb, :live_view

  import DevIdeWeb.WorkspaceLive.PickerBadges

  alias DevIDE.Files.PathSafety
  alias DevIDE.Workspaces
  alias DevIDE.Workspaces.PathResolver
  alias DevIDE.Workspaces.SessionSummary
  alias DevIdeWeb.NotificationsDrawer
  alias DevIdeWeb.NotificationsDrawerEvents
  alias DevIdeWeb.Plugs.ForwardAuth
  alias DevIdeWeb.WorkspaceRoutes

  @refresh_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) and Phoenix.LiveView.static_changed?(socket) do
      {:ok, redirect(socket, external: DevIdeWeb.Endpoint.url() <> ~p"/")}
    else
      if connected?(socket), do: :timer.send_interval(@refresh_ms, :refresh)

      user = socket.assigns.current_user
      is_admin = ForwardAuth.admin?(user)

      socket =
        socket
        |> assign(:page_title, "Workspaces")
        |> assign(:is_admin, is_admin)
        # Admins default to the cross-user view; the manager re-checks the
        # `?all=true` flag against its own admins list, so a non-admin
        # flipping this assign gains nothing.
        |> assign(:show_all, is_admin)
        |> assign(:error, nil)
        |> assign(:create_fields, DevIDE.WorkspaceSource.create_form_fields())
        |> assign(:form, initial_create_form(user))
        |> assign(:folder_form, folder_form())
        |> assign(:create_open, false)
        # Global notifications drawer (shared with the workspace cockpit):
        # subscribes to the viewer's notification topic and loads the unread
        # badge count on the connected mount; the inbox list is lazy (opens).
        |> NotificationsDrawerEvents.mount()

      # Fetch only on the connected mount — the static render shows an empty
      # shell. Keeps mount at exactly one upstream list call.
      socket =
        if connected?(socket) do
          load_workspaces(socket)
        else
          socket |> assign(:workspaces, []) |> assign(:workspace_index, %{})
        end

      {:ok, socket}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    if socket.redirected do
      {:noreply, socket}
    else
      # `?drawer=notifications` deep link (docs/deep_links.md) — the target of
      # the legacy `/notifications` redirect.
      socket = NotificationsDrawerEvents.apply_drawer_param(socket, params)
      {:noreply, browse(socket, normalize_dir(Map.get(params, "dir")))}
    end
  end

  @impl true
  # Durable notification broadcasts on the viewer's user topic — subscribed by
  # NotificationsDrawerEvents at mount. Badge always updates; the drawer list
  # refreshes only while open.
  def handle_info({:notification_created, _notification}, socket),
    do: {:noreply, NotificationsDrawerEvents.handle_notification_change(socket)}

  def handle_info({:notification_updated, _notification}, socket),
    do: {:noreply, NotificationsDrawerEvents.handle_notification_change(socket)}

  def handle_info(:refresh, %{assigns: %{show_all: true}} = socket), do: {:noreply, socket}

  def handle_info(:refresh, socket) do
    # Periodic poll: fetch off-process so the 5s tick never blocks the LiveView
    # on the upstream workspace-source call. The current list stays visible
    # until the refresh resolves.
    {:noreply, refresh_async(socket)}
  end

  @impl true
  def handle_async(:refresh_workspaces, {:ok, {:ok, workspaces}}, socket) do
    {:noreply,
     socket
     |> assign_workspaces(workspaces)
     |> assign(:error, nil)
     |> browse(socket.assigns.dir_rel)}
  end

  def handle_async(:refresh_workspaces, {:ok, {:error, reason}}, socket) do
    {:noreply, assign(socket, :error, format_error(reason))}
  end

  def handle_async(:refresh_workspaces, {:exit, _reason}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("start", %{"id" => id}, socket) do
    {:noreply, refresh_async(socket, &Workspaces.start(id, &1))}
  end

  def handle_event("stop", %{"id" => id}, socket) do
    {:noreply, refresh_async(socket, &Workspaces.stop(id, &1))}
  end

  def handle_event("create_toggle", _, socket),
    do: {:noreply, assign(socket, :create_open, not socket.assigns.create_open)}

  # Admin-only: flip between the cross-user view and the admin's own
  # workspaces. Re-checked server-side — `is_admin` was resolved from their
  # identity at mount and is never user-supplied.
  def handle_event("toggle_all", _, socket) do
    show_all = socket.assigns.is_admin and not socket.assigns.show_all

    socket =
      socket
      |> assign(:show_all, show_all)
      |> load_workspaces()

    {:noreply, browse(socket, socket.assigns.dir_rel)}
  end

  def handle_event("create", params, socket) do
    attrs =
      params
      |> Map.take(["name", "user", "type"])
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
      |> Map.new()

    case Workspaces.create(attrs, auth(socket)) do
      {:ok, _ws} ->
        {:noreply,
         socket |> assign(:error, nil) |> assign(:create_open, false) |> load_workspaces()}

      {:error, reason} ->
        {:noreply, assign(socket, :error, format_error(reason))}
    end
  end

  def handle_event("attach_folder", %{"folder" => %{"path" => path}}, socket) do
    {:noreply, open_folder(socket, path)}
  end

  def handle_event("attach_folder", _params, socket),
    do: {:noreply, assign(socket, :error, format_attach_error(:not_a_directory))}

  def handle_event("folder:open", %{"path" => path}, socket) do
    {:noreply, open_folder(socket, path)}
  end

  # Notifications drawer events are handled by NotificationsDrawerEvents
  # (absorbed from the removed NotificationLive.Index page; shared with the
  # workspace cockpit).
  def handle_event("notifications:" <> _ = event, params, socket),
    do: NotificationsDrawerEvents.handle_event(event, params, socket)

  # -- Directory browsing ----------------------------------------------------

  defp normalize_dir(dir) when is_binary(dir) do
    case String.trim(dir) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_dir(_), do: nil

  defp browse(socket, rel) do
    socket = socket |> assign(:dir_rel, rel) |> assign(:dir_error, nil)

    case dashboard_root() do
      nil ->
        socket |> assign(:dir_entries, []) |> assign(:dir_error, :missing_root)

      root ->
        case resolve_dir(root, rel, socket) do
          {:ok, dir} -> assign(socket, :dir_entries, list_dir_entries(dir, rel, socket))
          {:error, reason} -> socket |> assign(:dir_entries, []) |> assign(:dir_error, reason)
        end
    end
  end

  defp dashboard_root do
    case PathResolver.root() do
      root when is_binary(root) ->
        expanded = Path.expand(root)
        if File.dir?(expanded), do: expanded

      _ ->
        nil
    end
  end

  defp resolve_dir(root, nil, _socket), do: {:ok, root}

  defp resolve_dir(root, rel, socket) do
    # PathSafety rejects `..` escapes, symlinks leaving the root, and absurd
    # depth; the visibility check keeps forward-auth viewers inside their own
    # top-level directories even for hand-typed `?dir=` URLs.
    with {:ok, dir} <- PathSafety.resolve(root, rel),
         true <- File.dir?(dir) || {:error, :not_a_directory},
         true <- dir_rel_visible?(rel, socket) || {:error, :forbidden} do
      {:ok, dir}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp list_dir_entries(dir, rel, socket) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.filter(fn name ->
          not String.starts_with?(name, ".") and not PathSafety.ignored_dir?(name) and
            File.dir?(Path.join(dir, name))
        end)
        |> Enum.map(fn name ->
          entry_rel = if rel, do: Path.join(rel, name), else: name
          %{name: name, path: Path.join(dir, name), rel: entry_rel}
        end)
        |> Enum.filter(&dir_rel_visible?(&1.rel, socket))
        |> Enum.map(&Map.put(&1, :workspace, socket.assigns.workspace_index[&1.path]))

      {:error, _reason} ->
        []
    end
  end

  # A relative dir is visible when unrestricted, or when its top-level segment
  # either matches the viewer's identity (their own user directory) or holds a
  # workspace the viewer can already see.
  defp dir_rel_visible?(nil, _socket), do: true

  defp dir_rel_visible?(rel, socket) do
    if restricted?(socket) do
      case Path.split(rel) do
        [first | _] -> String.downcase(first) in allowed_first_segments(socket)
        [] -> true
      end
    else
      true
    end
  end

  defp restricted?(socket), do: ForwardAuth.enabled?() and not socket.assigns.show_all

  defp allowed_first_segments(socket) do
    identifiers = viewer_identifiers(socket.assigns.current_user)

    workspace_segments =
      case dashboard_root() do
        nil ->
          []

        root ->
          for ws <- socket.assigns.workspaces,
              path = workspace_field(ws, :path),
              is_binary(path),
              rel = relative_to_root(path, root),
              is_binary(rel),
              [first | _] <- [Path.split(rel)] do
            String.downcase(first)
          end
      end

    MapSet.new(identifiers ++ workspace_segments)
  end

  defp viewer_identifiers(user) when is_map(user) do
    [:id, :username, :email]
    |> Enum.map(fn key -> Map.get(user, key) || Map.get(user, Atom.to_string(key)) end)
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(fn value ->
      value = String.downcase(value)
      [value, value |> String.split("@") |> hd()]
    end)
    |> Enum.uniq()
  end

  defp viewer_identifiers(_user), do: []

  defp relative_to_root(path, root) do
    expanded = Path.expand(path)

    cond do
      expanded == root ->
        nil

      String.starts_with?(expanded, root <> "/") ->
        String.replace_prefix(expanded, root <> "/", "")

      true ->
        nil
    end
  end

  defp dir_crumbs(nil), do: []

  defp dir_crumbs(rel) do
    segments = Path.split(rel)

    segments
    |> Enum.with_index(1)
    |> Enum.map(fn {segment, index} ->
      %{label: segment, rel: segments |> Enum.take(index) |> Path.join()}
    end)
  end

  defp parent_rel(rel) do
    case rel |> Path.split() |> Enum.drop(-1) do
      [] -> nil
      segments -> Path.join(segments)
    end
  end

  defp dir_path(nil), do: ~p"/"
  defp dir_path(rel), do: ~p"/?#{[dir: rel]}"

  # -- Workspace listing (absorbed from the picker) ---------------------------

  defp auth(socket), do: socket.assigns.current_user[:email]

  defp list_opts(%{assigns: %{show_all: true}}), do: [all: true]
  defp list_opts(_socket), do: []

  defp initial_create_form(user) do
    fields = DevIDE.WorkspaceSource.create_form_fields()

    %{}
    |> Map.put_new("name", "")
    |> Map.put_new("user", if(:user in fields, do: user.id, else: nil))
    |> Map.put_new("type", if(:type in fields, do: "v3", else: nil))
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp folder_form(path \\ "") do
    Phoenix.Component.to_form(%{"path" => path}, as: :folder)
  end

  defp open_folder(socket, path) do
    if folder_openable?(socket, path) do
      case Workspaces.attach_folder(path) do
        {:ok, ws} ->
          push_navigate(socket, to: WorkspaceRoutes.workspace_path(ws, "local"))

        {:error, reason} ->
          socket
          |> assign(:folder_form, folder_form(path))
          |> assign(:error, format_attach_error(reason))
      end
    else
      assign(socket, :error, format_attach_error(:outside_allowed_roots))
    end
  end

  # Forward-auth viewers may only attach directories they can see on the
  # dashboard; everything else keeps the picker's allowed-roots behavior
  # (attach_folder re-checks those roots either way).
  defp folder_openable?(socket, path) do
    if restricted?(socket) do
      case dashboard_root() do
        nil -> false
        root -> dir_rel_visible?(relative_to_root(path, root), socket)
      end
    else
      true
    end
  end

  defp refresh_async(socket, action \\ fn _auth -> :ok end) do
    opts = list_opts(socket)
    auth = auth(socket)
    show_all = socket.assigns.show_all
    current_user = socket.assigns.current_user

    start_async(socket, :refresh_workspaces, fn ->
      _ = action.(auth)

      with {:ok, list} <- Workspaces.list(opts, auth) do
        {:ok,
         list |> filter_visible_workspaces(show_all, current_user) |> SessionSummary.build_many()}
      end
    end)
  end

  defp load_workspaces(socket) do
    case Workspaces.list(list_opts(socket), auth(socket)) do
      {:ok, list} ->
        workspaces =
          list
          |> filter_visible_workspaces(socket.assigns.show_all, socket.assigns.current_user)
          |> SessionSummary.build_many()

        socket |> assign_workspaces(workspaces) |> assign(:error, nil)

      {:error, reason} ->
        socket |> assign_workspaces([]) |> assign(:error, format_error(reason))
    end
  end

  defp assign_workspaces(socket, workspaces) do
    index =
      for ws <- workspaces,
          path = workspace_field(ws, :path),
          is_binary(path) and path != "",
          into: %{} do
        {Path.expand(path), ws}
      end

    socket |> assign(:workspaces, workspaces) |> assign(:workspace_index, index)
  end

  defp workspace_field(ws, key) when is_atom(key),
    do: Map.get(ws, key) || Map.get(ws, Atom.to_string(key))

  defp filter_visible_workspaces(workspaces, show_all, current_user) do
    if ForwardAuth.enabled?() and not show_all do
      Enum.filter(workspaces, &Workspaces.viewer_owns_workspace?(&1, current_user))
    else
      workspaces
    end
  end

  defp format_error({:transport, %{reason: :econnrefused}}),
    do: "Workspace source is not reachable."

  defp format_error({:transport, reason}), do: "Transport error: #{inspect(reason)}"
  defp format_error({:http, status, body}), do: "Source HTTP #{status}: #{inspect(body)}"
  defp format_error(other), do: inspect(other)

  defp format_attach_error(:not_a_directory), do: "Folder path is not a directory."

  defp format_attach_error(:outside_allowed_roots),
    do: "Folder path is outside the allowed roots."

  defp format_dir_error(:missing_root), do: "No browsable path root is configured."
  defp format_dir_error(:forbidden), do: "This directory belongs to another user."
  defp format_dir_error(:not_a_directory), do: "Not a directory."
  defp format_dir_error(:outside_root), do: "Directory is outside the path root."
  defp format_dir_error(:symlink_escape), do: "Directory link leaves the path root."
  defp format_dir_error(:too_deep), do: "Directory is nested too deeply."
  defp format_dir_error(other), do: "Directory error: #{inspect(other)}"

  defp workspace_path(workspace, host_id \\ "local"),
    do: WorkspaceRoutes.workspace_path(workspace, host_id)

  # History side panel deep link inside the workspace cockpit (?tab=history).
  defp history_path(ws) do
    base = workspace_path(ws)
    join = if String.contains?(base, "?"), do: "&", else: "?"
    base <> join <> "tab=history"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-full p-6 space-y-6">
      <header>
        <div class="flex items-start justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold tracking-tight">Workspaces</h1>
            <p class="text-sm text-zinc-500 mt-1">
              Directories under the path root. Rows with sessions open straight
              into the cockpit — the URL is the filesystem path.
            </p>
          </div>
          <div class="flex shrink-0 items-center gap-2">
            <%= if @is_admin do %>
              <button
                phx-click="toggle_all"
                class="shrink-0 text-xs font-mono px-2 py-1 rounded border border-zinc-300 hover:bg-zinc-100"
                title="Admin: switch between all users' workspaces and your own"
              >
                {if @show_all, do: "showing: all users", else: "showing: mine"}
              </button>
            <% end %>
            <NotificationsDrawer.notifications_bell unread_count={@notif_unread_count} />
          </div>
        </div>
      </header>

      <%= if @error do %>
        <div class="rounded border border-red-300 bg-red-50 p-3 text-sm text-red-800">
          {@error}
        </div>
      <% end %>

      <section id="dashboard-browser" class="rounded border border-zinc-200 overflow-hidden">
        <div class="flex items-center gap-2 border-b bg-zinc-50 px-4 py-2 text-sm">
          <nav id="dashboard-crumbs" class="flex min-w-0 flex-1 items-center gap-1 font-mono text-xs">
            <.link patch={dir_path(nil)} class="shrink-0 text-blue-700 hover:underline">root</.link>
            <%= for crumb <- dir_crumbs(@dir_rel) do %>
              <span class="text-zinc-400">/</span>
              <.link patch={dir_path(crumb.rel)} class="truncate text-blue-700 hover:underline">
                {crumb.label}
              </.link>
            <% end %>
          </nav>
          <%= if @dir_rel do %>
            <.link
              patch={dir_path(parent_rel(@dir_rel))}
              class="shrink-0 rounded border border-zinc-300 bg-white px-2 py-0.5 text-xs text-zinc-700 hover:bg-zinc-100"
            >
              Up
            </.link>
          <% end %>
        </div>

        <%= if @dir_error do %>
          <p class="px-4 py-4 text-sm text-amber-700">{format_dir_error(@dir_error)}</p>
        <% else %>
          <%= if @dir_entries == [] do %>
            <p class="px-4 py-4 text-sm text-zinc-400 italic">No directories.</p>
          <% else %>
            <ul id="dashboard-dirs">
              <li
                :for={entry <- @dir_entries}
                class="flex flex-wrap items-center gap-2 border-b border-zinc-100 px-4 py-2 last:border-b-0 hover:bg-zinc-50/50"
                data-dir={entry.rel}
              >
                <.link
                  patch={dir_path(entry.rel)}
                  class="min-w-0 font-mono text-sm text-blue-700 hover:underline"
                >
                  {entry.name}/
                </.link>

                <%= if ws = entry.workspace do %>
                  <span class={status_class(ws.status)}>{ws.status}</span>
                  <%= if layout_status = workspace_agent_layout_status(ws) do %>
                    <span
                      class={workspace_agent_layout_class(layout_status)}
                      title={workspace_agent_layout_title(ws)}
                    >
                      <.icon name={workspace_agent_layout_icon(layout_status)} class="size-3" />
                      {workspace_agent_layout_label(layout_status)}
                    </span>
                  <% end %>
                  <%= for session <- Enum.take(ws.sessions, 4) do %>
                    <span class="inline-flex items-center gap-0.5">
                      <.link
                        navigate={session.href}
                        class="rounded border border-zinc-200 bg-white px-1.5 py-0.5 text-[10px] text-zinc-600 hover:border-zinc-400 hover:text-zinc-900"
                        title={session.title || session.cwd || session.tmux_session || session.id}
                      >
                        {session.label}
                      </.link>
                      <%= if status = session_agent_status(session) do %>
                        <span
                          class={agent_session_status_class(status)}
                          title={session_agent_status_title(session)}
                        >
                          {status}
                        </span>
                      <% end %>
                    </span>
                  <% end %>
                  <span class="flex-1"></span>
                  <div class="inline-flex items-center gap-2">
                    <.link
                      navigate={workspace_path(ws)}
                      class="rounded border border-zinc-200 px-2 py-0.5 text-xs text-zinc-700 hover:bg-zinc-100"
                    >
                      Open
                    </.link>
                    <.link
                      navigate={history_path(ws)}
                      class="inline-flex items-center gap-1 rounded border border-zinc-200 px-2 py-0.5 text-xs text-zinc-700 hover:bg-zinc-100"
                      title="Search previous session context"
                    >
                      <.icon name="hero-clock" class="size-3" /> History
                    </.link>
                    <%= if ws.status == :running do %>
                      <button
                        phx-click="stop"
                        phx-value-id={ws.id}
                        class="text-xs px-2 py-0.5 rounded border hover:bg-zinc-100"
                      >
                        stop
                      </button>
                    <% else %>
                      <button
                        phx-click="start"
                        phx-value-id={ws.id}
                        class="text-xs px-2 py-0.5 rounded border hover:bg-zinc-100"
                      >
                        start
                      </button>
                    <% end %>
                  </div>
                <% else %>
                  <span class="flex-1"></span>
                  <button
                    type="button"
                    phx-click="folder:open"
                    phx-value-path={entry.path}
                    class="rounded border border-zinc-300 px-2 py-1 text-xs text-zinc-700 hover:bg-zinc-100"
                  >
                    Open
                  </button>
                <% end %>
              </li>
            </ul>
          <% end %>
        <% end %>
      </section>

      <section :if={@workspaces != []} class="rounded border border-zinc-200 overflow-hidden">
        <table class="w-full text-sm">
          <thead class="text-left text-zinc-500 text-xs">
            <tr>
              <th class="py-2 px-4">Name</th>
              <th>Path</th>
              <th>User</th>
              <th>Branch</th>
              <th>Changes</th>
              <th>Runtimes</th>
              <th>Sessions</th>
              <th>Status</th>
              <th class="text-right pr-4">Actions</th>
            </tr>
          </thead>
          <tbody>
            <%= for ws <- @workspaces do %>
              <tr class="border-t hover:bg-zinc-50/50">
                <td class="py-2 px-4">
                  <.link
                    navigate={workspace_path(ws)}
                    class="text-blue-700 hover:underline font-medium"
                  >
                    {ws.name}
                  </.link>
                </td>
                <td class="max-w-60 truncate font-mono text-xs text-zinc-500" title={ws.path || ""}>
                  {ws.path_label || "—"}
                </td>
                <td class="text-zinc-600">{ws.user}</td>
                <td class="font-mono text-xs text-zinc-600">{ws.branch || "—"}</td>
                <td class="font-mono text-xs text-zinc-600">
                  <%= if is_integer(ws.dirty_count) do %>
                    {ws.dirty_count}
                  <% else %>
                    —
                  <% end %>
                </td>
                <td class="font-mono text-xs text-zinc-600">
                  {ws.active_runtime_count}/{ws.runtime_count}
                </td>
                <td class="font-mono text-xs text-zinc-600">
                  <div class="flex flex-wrap items-center gap-1">
                    <span>{ws.session_count}</span>
                    <%= if layout_status = workspace_agent_layout_status(ws) do %>
                      <span
                        class={workspace_agent_layout_class(layout_status)}
                        title={workspace_agent_layout_title(ws)}
                      >
                        <.icon name={workspace_agent_layout_icon(layout_status)} class="size-3" />
                        {workspace_agent_layout_label(layout_status)}
                      </span>
                    <% end %>
                    <%= for session <- Enum.take(ws.sessions, 4) do %>
                      <span class="inline-flex items-center gap-0.5">
                        <.link
                          navigate={session.href}
                          class="rounded border border-zinc-200 bg-white px-1.5 py-0.5 text-[10px] text-zinc-600 hover:border-zinc-400 hover:text-zinc-900"
                          title={session.title || session.cwd || session.tmux_session || session.id}
                        >
                          {session.label}
                        </.link>
                        <%= if status = session_agent_status(session) do %>
                          <span
                            class={agent_session_status_class(status)}
                            title={session_agent_status_title(session)}
                          >
                            {status}
                          </span>
                        <% end %>
                        <button
                          type="button"
                          data-copy-session-link={session_share_url(session.href)}
                          data-copy-link-kind="session"
                          class="rounded border border-zinc-200 bg-white p-0.5 text-zinc-500 hover:border-zinc-400 hover:text-zinc-900"
                          title={"Copy link to " <> session.label}
                          aria-label={"Copy link to " <> session.label}
                        >
                          <.icon name="hero-link" class="size-3" />
                        </button>
                      </span>
                    <% end %>
                  </div>
                </td>
                <td><span class={status_class(ws.status)}>{ws.status}</span></td>
                <td class="text-right pr-4">
                  <div class="inline-flex items-center justify-end gap-2">
                    <.link
                      navigate={history_path(ws)}
                      class="inline-flex items-center gap-1 rounded border border-zinc-200 px-2 py-0.5 text-xs text-zinc-700 hover:bg-zinc-100"
                      title="Search previous session context"
                    >
                      <.icon name="hero-clock" class="size-3" /> History
                    </.link>

                    <%= if ws.status == :running do %>
                      <button
                        phx-click="stop"
                        phx-value-id={ws.id}
                        class="text-xs px-2 py-0.5 rounded border hover:bg-zinc-100"
                      >
                        stop
                      </button>
                    <% else %>
                      <button
                        phx-click="start"
                        phx-value-id={ws.id}
                        class="text-xs px-2 py-0.5 rounded border hover:bg-zinc-100"
                      >
                        start
                      </button>
                    <% end %>
                  </div>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </section>

      <section class="rounded border border-zinc-200 bg-zinc-50 p-4">
        <.form
          id="attach-folder-form"
          for={@folder_form}
          phx-submit="attach_folder"
          class="flex flex-col gap-2 sm:flex-row sm:items-end"
        >
          <div class="min-w-0 flex-1">
            <.input
              field={@folder_form[:path]}
              type="text"
              label="Folder path"
              placeholder="/data/workspaces/user/project"
              class="mt-1 block w-full rounded border border-zinc-300 bg-white px-2 py-1 font-mono text-sm text-zinc-900 shadow-sm transition focus:border-zinc-500 focus:outline-none focus:ring-2 focus:ring-zinc-200"
              required
            />
          </div>
          <button class="rounded bg-zinc-900 px-3 py-1.5 text-sm text-white hover:bg-zinc-700">
            Open folder
          </button>
          <button
            type="button"
            phx-click="create_toggle"
            class="text-xs underline text-zinc-600 hover:text-zinc-900"
          >
            + new workspace
          </button>
        </.form>
      </section>

      <%= if @create_open do %>
        <section class="rounded border border-zinc-200 p-4 bg-zinc-50">
          <h2 class="mb-2 font-medium text-sm">
            Create workspace
          </h2>
          <.form for={%{}} as={:ws} phx-submit="create" class="flex flex-wrap gap-2 items-end">
            <%= if :name in @create_fields do %>
              <label class="text-sm">
                Name
                <input
                  name="name"
                  value={@form["name"]}
                  class="block border rounded px-2 py-1"
                  required
                />
              </label>
            <% end %>

            <%= if :user in @create_fields do %>
              <label class="text-sm">
                User
                <input
                  name="user"
                  value={@form["user"]}
                  class="block border rounded px-2 py-1"
                  required
                />
              </label>
            <% end %>

            <%= if :type in @create_fields do %>
              <label class="text-sm">
                Type
                <select name="type" class="block border rounded px-2 py-1">
                  <option value="v3" selected>v3</option>
                  <option value="legacy">legacy</option>
                </select>
              </label>
            <% end %>

            <button class="rounded bg-zinc-900 text-white px-3 py-1.5 text-sm">Create</button>
            <button
              type="button"
              phx-click="create_toggle"
              class="text-xs underline text-zinc-500 self-center"
            >
              cancel
            </button>
          </.form>
        </section>
      <% end %>

      <NotificationsDrawer.notifications_drawer
        open={@notif_drawer_open}
        loaded?={@notif_loaded?}
        notifications={@notifications}
        unread_count={@notif_unread_count}
        user_id={@notif_user_id}
        error={@notif_error}
        info={@notif_info}
        preferences={@notif_preferences}
        preferences_form={@notif_preferences_form}
        admin?={@notif_admin?}
        device_stats={@notif_device_stats}
        devices={@notif_devices}
      />
    </div>
    """
  end
end
