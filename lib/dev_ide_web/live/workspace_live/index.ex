defmodule DevIdeWeb.WorkspaceLive.Index do
  @moduledoc """
  Connection picker (product.md §9.1).

  The first screen. Single-runtime: the cockpit serves one local host, so the
  picker renders a single "local" card with a capability summary, listing every
  workspace beneath it.
  """

  use DevIdeWeb, :live_view

  alias DevIDE.Workspaces
  alias DevIDE.Workspaces.SessionSummary
  alias DevIdeWeb.Plugs.ForwardAuth
  alias DevIdeWeb.WorkspaceRoutes

  @refresh_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) and Phoenix.LiveView.static_changed?(socket) do
      {:ok, redirect(socket, external: DevIdeWeb.Endpoint.url() <> ~p"/workspaces")}
    else
      if connected?(socket), do: :timer.send_interval(@refresh_ms, :refresh)

      user = socket.assigns.current_user
      is_admin = ForwardAuth.admin?(user)

      socket =
        socket
        |> assign(:page_title, "Connect")
        |> assign(:is_admin, is_admin)
        # Admins default to the cross-user view; the manager still re-checks the
        # `?all=true` flag against its own admins list, so a non-admin flipping
        # this assign gains nothing.
        |> assign(:show_all, is_admin)
        |> assign(:error, nil)
        |> assign(:create_fields, DevIDE.WorkspaceSource.create_form_fields())
        |> assign(:form, initial_create_form(user))
        |> assign(:folder_form, folder_form())
        |> assign(:folder_browser, load_folder_browser(nil))
        |> assign(:create_open, false)

      # Fetch only on the connected mount — the static render shows an empty
      # shell. This keeps mount at exactly one upstream list call instead of
      # two (disconnected + connected), which the picker-refresh tests assert.
      socket =
        if connected?(socket) do
          load_picker(socket)
        else
          socket
          |> assign(:workspaces, [])
          |> assign(:hosts, build_hosts([]))
        end

      {:ok, socket}
    end
  end

  @impl true
  def handle_info(:refresh, %{assigns: %{show_all: true}} = socket), do: {:noreply, socket}

  def handle_info(:refresh, socket) do
    # Periodic poll: fetch off-process so the 5s tick never blocks the LiveView
    # on the upstream workspace-source call (Workspaces.list is a remote call).
    # The current list stays visible until the refresh resolves — no flicker,
    # and a transient error doesn't blank the picker.
    {:noreply, refresh_async(socket)}
  end

  @impl true
  def handle_async(:refresh_picker, {:ok, {:ok, workspaces}}, socket) do
    {:noreply,
     socket
     |> assign(:workspaces, workspaces)
     |> assign(:hosts, build_hosts(workspaces))
     |> assign(:error, nil)}
  end

  def handle_async(:refresh_picker, {:ok, {:error, reason}}, socket) do
    {:noreply, assign(socket, :error, format_error(reason))}
  end

  def handle_async(:refresh_picker, {:exit, _reason}, socket) do
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
  # workspaces. Re-checked server-side — a non-admin posting this event still
  # gets `show_all: false` because `is_admin` was resolved from their identity
  # at mount and is never user-supplied.
  def handle_event("toggle_all", _, socket) do
    show_all = socket.assigns.is_admin and not socket.assigns.show_all
    {:noreply, socket |> assign(:show_all, show_all) |> load_picker()}
  end

  def handle_event("create", params, socket) do
    # Only pass the fields the current source cares about
    attrs =
      params
      |> Map.take(["name", "user", "type"])
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
      |> Map.new()

    case Workspaces.create(attrs, auth(socket)) do
      {:ok, _ws} ->
        {:noreply, socket |> assign(:error, nil) |> assign(:create_open, false) |> load_picker()}

      {:error, reason} ->
        {:noreply, assign(socket, :error, format_error(reason))}
    end
  end

  def handle_event("attach_folder", %{"folder" => %{"path" => path}}, socket) do
    {:noreply, open_folder(socket, path)}
  end

  def handle_event("attach_folder", _params, socket),
    do: {:noreply, assign(socket, :error, format_attach_error(:not_a_directory))}

  def handle_event("folder:browse", %{"path" => path}, socket) do
    {:noreply, assign(socket, :folder_browser, load_folder_browser(path))}
  end

  def handle_event("folder:open", %{"path" => path}, socket) do
    {:noreply, open_folder(socket, path)}
  end

  # Forward-auth email for the current user — the manager scopes the response
  # to that user (filters the list, attributes mutations). Falls back to the
  # static config when the identity has no email (local single-user dev).
  defp auth(socket), do: socket.assigns.current_user[:email]

  # `all: true` asks the manager for every user's workspaces. The manager
  # honors it only for callers in its own admins list, so this is safe to send
  # whenever the local identity resolved to admin.
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

  defp load_folder_browser(path) do
    case Workspaces.list_attachable_folders(path) do
      {:ok, listing} ->
        Map.put(listing, :error, nil)

      {:error, reason} ->
        %{path: path, parent: nil, roots: Workspaces.allowed_roots(), entries: [], error: reason}
    end
  end

  defp open_folder(socket, path) do
    case Workspaces.attach_folder(path) do
      {:ok, ws} ->
        push_navigate(socket, to: workspace_path(ws, "local"))

      {:error, reason} ->
        socket
        |> assign(:folder_form, folder_form(path))
        |> assign(:error, format_attach_error(reason))
    end
  end

  # Refresh the picker off-process so neither the 5s tick nor the start/stop
  # buttons block the LiveView on the upstream workspace-source call. An
  # optional `action` (start/stop) runs in the same async task before the list
  # fetch, so the click returns immediately and the new list lands via
  # handle_async(:refresh_picker, ...).
  defp refresh_async(socket, action \\ fn _auth -> :ok end) do
    opts = list_opts(socket)
    auth = auth(socket)
    show_all = socket.assigns.show_all
    current_user = socket.assigns.current_user

    start_async(socket, :refresh_picker, fn ->
      _ = action.(auth)

      with {:ok, list} <- Workspaces.list(opts, auth) do
        {:ok,
         list |> filter_visible_workspaces(show_all, current_user) |> SessionSummary.build_many()}
      end
    end)
  end

  defp load_picker(socket) do
    case Workspaces.list(list_opts(socket), auth(socket)) do
      {:ok, list} ->
        workspaces =
          list
          |> filter_visible_workspaces(socket.assigns.show_all, socket.assigns.current_user)
          |> SessionSummary.build_many()

        socket
        |> assign(:workspaces, workspaces)
        |> assign(:hosts, build_hosts(workspaces))
        |> assign(:error, nil)

      {:error, reason} ->
        socket
        |> assign(:workspaces, [])
        |> assign(:hosts, build_hosts([]))
        |> assign(:error, format_error(reason))
    end
  end

  # Single-runtime: the cockpit serves exactly one local host, so the picker
  # always renders a single "local" card holding every workspace. (Multi-host
  # fleet placement was removed — a workspace runs on the box serving this
  # cockpit.)
  defp build_hosts(workspaces) do
    [
      %{
        id: "local",
        os: current_os(),
        capabilities: ["tmux", "git", "audit", "replay", "policy"],
        tools: ["mix", "git", "tmux"],
        mode: :local,
        latency: "0ms",
        workspaces: workspaces
      }
    ]
  end

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

  defp format_attach_error(:enoent), do: "Folder path is not available."
  defp format_attach_error(:eacces), do: "Folder path is not readable."
  defp format_attach_error(other), do: "Folder error: #{inspect(other)}"

  defp current_os do
    case :os.type() do
      {:unix, :darwin} -> "darwin"
      {:unix, _} -> "linux"
      {:win32, _} -> "windows"
      _ -> "unknown"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-full p-6 space-y-6">
      <header>
        <div class="flex items-start justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold tracking-tight">Connect to a workspace</h1>
            <p class="text-sm text-zinc-500 mt-1">
              Pick a host, then a workspace. The cockpit is the same regardless of
              where the runtime lives — <span class="text-zinc-700">local or remote</span>.
            </p>
          </div>
          <%= if @is_admin do %>
            <button
              phx-click="toggle_all"
              class="shrink-0 text-xs font-mono px-2 py-1 rounded border border-zinc-300 hover:bg-zinc-100"
              title="Admin: switch between all users' workspaces and your own"
            >
              {if @show_all, do: "showing: all users", else: "showing: mine"}
            </button>
          <% end %>
        </div>
      </header>

      <%= if @error do %>
        <div class="rounded border border-red-300 bg-red-50 p-3 text-sm text-red-800">
          {@error}
        </div>
      <% end %>

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
              placeholder="/data/workspaces/dalexandre/project"
              class="mt-1 block w-full rounded border border-zinc-300 bg-white px-2 py-1 font-mono text-sm text-zinc-900 shadow-sm transition focus:border-zinc-500 focus:outline-none focus:ring-2 focus:ring-zinc-200"
              required
            />
          </div>
          <button class="rounded bg-zinc-900 px-3 py-1.5 text-sm text-white hover:bg-zinc-700">
            Open folder
          </button>
        </.form>

        <div class="mt-4 space-y-3">
          <div class="flex flex-wrap items-center gap-2 text-xs">
            <%= for root <- @folder_browser.roots do %>
              <button
                type="button"
                phx-click="folder:browse"
                phx-value-path={root}
                class="rounded border border-zinc-300 bg-white px-2 py-1 font-mono text-zinc-700 hover:bg-zinc-100"
              >
                {root}
              </button>
            <% end %>
          </div>

          <%= if @folder_browser.error do %>
            <p class="text-sm text-red-700">{format_attach_error(@folder_browser.error)}</p>
          <% else %>
            <div class="flex items-center gap-2 text-sm">
              <%= if @folder_browser.parent do %>
                <button
                  type="button"
                  phx-click="folder:browse"
                  phx-value-path={@folder_browser.parent}
                  class="rounded border border-zinc-300 bg-white px-2 py-1 text-zinc-700 hover:bg-zinc-100"
                >
                  Up
                </button>
              <% end %>
              <span class="min-w-0 truncate font-mono text-xs text-zinc-600">
                {@folder_browser.path}
              </span>
            </div>

            <%= if @folder_browser.entries == [] do %>
              <p class="text-sm text-zinc-500">No folders.</p>
            <% else %>
              <div class="max-h-80 overflow-auto rounded border border-zinc-200 bg-white">
                <%= for entry <- @folder_browser.entries do %>
                  <div class="flex items-center gap-2 border-b border-zinc-100 px-3 py-2 last:border-b-0">
                    <button
                      type="button"
                      phx-click="folder:browse"
                      phx-value-path={entry.path}
                      class="min-w-0 flex-1 truncate text-left font-mono text-sm text-blue-700 hover:underline"
                    >
                      {entry.name}
                    </button>
                    <button
                      type="button"
                      phx-click="folder:open"
                      phx-value-path={entry.path}
                      class="rounded border border-zinc-300 px-2 py-1 text-xs text-zinc-700 hover:bg-zinc-100"
                    >
                      Open
                    </button>
                  </div>
                <% end %>
              </div>
            <% end %>
          <% end %>
        </div>
      </section>

      <ul class="space-y-3">
        <%= for host <- @hosts do %>
          <li class="rounded border border-zinc-200 overflow-hidden">
            <div class="flex items-center gap-3 px-4 py-3 bg-zinc-50 border-b">
              <span class={"text-[10px] font-mono uppercase tracking-wider px-2 py-0.5 rounded " <> mode_class(host.mode)}>
                {host.mode}
              </span>
              <div class="flex-1">
                <div class="text-sm font-medium">{host.id}</div>
                <div class="text-[11px] text-zinc-500 font-mono">
                  {host.os || "—"}
                  <%= if host.latency do %>
                    · {host.latency}
                  <% end %>
                </div>
              </div>
              <div class="flex flex-wrap gap-1 max-w-xs justify-end">
                <%= for cap <- host.capabilities do %>
                  <span class="text-[10px] font-mono px-1.5 py-0.5 rounded bg-white border text-zinc-600">
                    {cap}
                  </span>
                <% end %>
              </div>
            </div>

            <%= if host.workspaces == [] do %>
              <p class="px-4 py-4 text-sm text-zinc-400 italic">
                No workspaces on this host.
                <%= if host.id == "local" do %>
                  <button
                    phx-click="create_toggle"
                    class="ml-1 underline text-zinc-600 hover:text-zinc-900"
                  >
                    Create one
                  </button>
                <% end %>
              </p>
            <% else %>
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
                  <%= for ws <- host.workspaces do %>
                    <tr class="border-t hover:bg-zinc-50/50">
                      <td class="py-2 px-4">
                        <.link
                          navigate={workspace_path(ws.id, host.id)}
                          class="text-blue-700 hover:underline font-medium"
                        >
                          {ws.name}
                        </.link>
                      </td>
                      <td
                        class="max-w-60 truncate font-mono text-xs text-zinc-500"
                        title={ws.path || ""}
                      >
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
                              <.icon
                                name={workspace_agent_layout_icon(layout_status)}
                                class="size-3"
                              />
                              {workspace_agent_layout_label(layout_status)}
                            </span>
                          <% end %>
                          <%= for session <- Enum.take(ws.sessions, 4) do %>
                            <span class="inline-flex items-center gap-0.5">
                              <.link
                                navigate={session.href}
                                class="rounded border border-zinc-200 bg-white px-1.5 py-0.5 text-[10px] text-zinc-600 hover:border-zinc-400 hover:text-zinc-900"
                                title={
                                  session.title || session.cwd || session.tmux_session || session.id
                                }
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
                                data-copy-session-link={picker_session_share_url(session.href)}
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
                            navigate={previous_sessions_path(ws.id)}
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
              <%= if host.id == "local" do %>
                <div class="px-4 py-2 border-t bg-zinc-50/50 text-right">
                  <button
                    phx-click="create_toggle"
                    class="text-xs underline text-zinc-600 hover:text-zinc-900"
                  >
                    + new workspace
                  </button>
                </div>
              <% end %>
            <% end %>
          </li>
        <% end %>
      </ul>

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

      <footer class="text-[11px] text-zinc-400 font-mono pt-4 border-t border-zinc-100">
        product.md §9.1 · mode derived from capabilities, not declared · hide rather than mock
      </footer>
    </div>
    """
  end

  defp mode_class(:local), do: "bg-green-50 text-green-700 border border-green-200"
  defp mode_class(:remote), do: "bg-blue-50 text-blue-700 border border-blue-200"
  defp mode_class(_), do: "bg-zinc-50 text-zinc-600 border border-zinc-200"

  defp status_class(:running), do: "text-green-700"
  defp status_class(:stopped), do: "text-zinc-500"
  defp status_class(_), do: "text-amber-700"

  defp session_agent_status(%{agent_status: status}) when is_binary(status) and status != "",
    do: status

  defp session_agent_status(%{"agent_status" => status}) when is_binary(status) and status != "",
    do: status

  defp session_agent_status(_session), do: nil

  defp workspace_agent_layout_status(ws) do
    layout = Map.get(ws, :agent_layout) || Map.get(ws, "agent_layout") || %{}

    case Map.get(layout, :status) || Map.get(layout, "status") do
      "ready" -> "ready"
      "missing_agent_pane" -> "missing_agent_pane"
      _ -> nil
    end
  end

  defp workspace_agent_layout_label("ready"), do: "agent ready"
  defp workspace_agent_layout_label("missing_agent_pane"), do: "agent pane missing"

  defp workspace_agent_layout_icon("ready"), do: "hero-check-circle"
  defp workspace_agent_layout_icon("missing_agent_pane"), do: "hero-exclamation-triangle"

  defp workspace_agent_layout_class("ready") do
    "inline-flex items-center gap-0.5 rounded border border-emerald-200 bg-emerald-50 px-1.5 py-0.5 text-[10px] font-medium text-emerald-700"
  end

  defp workspace_agent_layout_class("missing_agent_pane") do
    "inline-flex items-center gap-0.5 rounded border border-amber-200 bg-amber-50 px-1.5 py-0.5 text-[10px] font-medium text-amber-800"
  end

  defp workspace_agent_layout_title(ws) do
    layout = Map.get(ws, :agent_layout) || Map.get(ws, "agent_layout") || %{}

    case Map.get(layout, :suggested_template) || Map.get(layout, "suggested_template") do
      template when is_binary(template) and template != "" ->
        "Role-marked agent pane: #{template}"

      _ ->
        "Role-marked agent pane"
    end
  end

  defp session_agent_status_title(session) do
    title =
      Map.get(session, :agent_title) ||
        Map.get(session, "agent_title") ||
        Map.get(session, :title) ||
        Map.get(session, "title")

    case title do
      value when is_binary(value) and value != "" -> value
      _ -> "Latest agent prompt status"
    end
  end

  defp agent_session_status_class("attention"),
    do: "rounded border border-red-200 bg-red-50 px-1 py-0.5 text-[10px] font-medium text-red-700"

  defp agent_session_status_class("done"),
    do:
      "rounded border border-emerald-200 bg-emerald-50 px-1 py-0.5 text-[10px] font-medium text-emerald-700"

  defp agent_session_status_class("running"),
    do:
      "rounded border border-blue-200 bg-blue-50 px-1 py-0.5 text-[10px] font-medium text-blue-700"

  defp agent_session_status_class(_status),
    do:
      "rounded border border-zinc-200 bg-zinc-50 px-1 py-0.5 text-[10px] font-medium text-zinc-600"

  defp picker_session_share_url(href) when is_binary(href) and href != "" do
    DevIdeWeb.Endpoint.url() <> href
  end

  defp workspace_path(workspace, host_id), do: WorkspaceRoutes.workspace_path(workspace, host_id)

  defp previous_sessions_path(id), do: ~p"/workspaces/#{id}/previous-sessions"
end
