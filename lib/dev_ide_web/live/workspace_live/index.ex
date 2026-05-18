defmodule DevIdeWeb.WorkspaceLive.Index do
  @moduledoc """
  Connection picker (product.md §9.1).

  The first screen. A flat list of hosts the client knows about, each
  with a derived mode badge and capability summary. Workspaces are
  listed under the host they live on. Mode is derived from
  capabilities (product.md §11), not declared.

  At this milestone the picker realistically shows one host
  (this machine) but the structure supports multiples — that is the
  FP-4 / FP-5 promise.
  """

  use DevIdeWeb, :live_view

  alias DevIDE.{Runtimes, Workspaces}
  alias DevIdeWeb.Plugs.{AssignCurrentUser, ForwardAuth}

  @refresh_ms 5_000

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_ms, :refresh)

    user = AssignCurrentUser.from_session(session)
    is_admin = ForwardAuth.admin?(user)

    {:ok,
     socket
     |> assign(:page_title, "Connect")
     |> assign(:current_user, user)
     |> assign(:is_admin, is_admin)
     # Admins default to the cross-user view; the manager still re-checks the
     # `?all=true` flag against its own admins list, so a non-admin flipping
     # this assign gains nothing.
     |> assign(:show_all, is_admin)
     |> assign(:error, nil)
     |> assign(:create_fields, DevIDE.WorkspaceSource.create_form_fields())
     |> assign(:form, initial_create_form(user))
     |> assign(:create_open, false)
     |> load_picker()}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load_picker(socket)}

  @impl true
  def handle_event("start", %{"id" => id}, socket) do
    _ = Workspaces.start(id, auth(socket))
    {:noreply, load_picker(socket)}
  end

  def handle_event("stop", %{"id" => id}, socket) do
    _ = Workspaces.stop(id, auth(socket))
    {:noreply, load_picker(socket)}
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

  defp load_picker(socket) do
    case Workspaces.list(list_opts(socket), auth(socket)) do
      {:ok, list} ->
        socket
        |> assign(:workspaces, list)
        |> assign(:hosts, build_hosts(list))
        |> assign(:error, nil)

      {:error, reason} ->
        socket
        |> assign(:workspaces, [])
        |> assign(:hosts, build_hosts([]))
        |> assign(:error, format_error(reason))
    end
  end

  # Combine the registered runtime hosts (Runtimes.list_hosts/0) with a
  # synthetic "this machine" entry when no host has been registered yet,
  # so the picker always has something honest to show. Workspaces are
  # attached to the host whose id matches their runtime host_id, or to
  # the local host by default.
  defp build_hosts(workspaces) do
    registered = Runtimes.list_hosts()
    hosts = if registered == [], do: [synthetic_local_host()], else: registered

    Enum.map(hosts, fn h ->
      %{
        id: h.id,
        os: h.os,
        capabilities: h.capabilities || [],
        tools: h.tools || [],
        mode: derive_mode(h),
        latency: derive_latency(h),
        workspaces: workspaces_on(workspaces, h.id)
      }
    end)
  end

  defp synthetic_local_host do
    %DevIDE.Runtimes.Host{
      id: "local",
      os: current_os(),
      capabilities: ["tmux", "git", "audit", "replay", "policy"],
      tools: ["mix", "git", "tmux"],
      concurrency_limit: 1,
      heartbeat_at: DateTime.utc_now(),
      metadata: %{}
    }
  end

  # FP-4 / product.md §11: mode is derived, not declared.
  # No scheduler → not fleet.
  # Host id "local" or no remote indicator → local.
  # Otherwise → remote.
  defp derive_mode(%{metadata: meta} = host) do
    cond do
      Map.get(meta || %{}, "scheduler") in ["jx"] -> :fleet
      host.id in ["local", "localhost"] -> :local
      true -> :remote
    end
  end

  defp derive_latency(%{id: "local"}), do: "0ms"
  defp derive_latency(%{metadata: %{"latency_ms" => ms}}), do: "#{ms}ms"
  defp derive_latency(_), do: nil

  defp workspaces_on(workspaces, host_id) do
    Enum.filter(workspaces, fn ws ->
      (Map.get(ws, :host_id) || Map.get(ws, :host) || "local") == host_id
    end)
  end

  defp format_error({:transport, %{reason: :econnrefused}}),
    do: "Workspace source is not reachable."

  defp format_error({:transport, reason}), do: "Transport error: #{inspect(reason)}"
  defp format_error({:http, status, body}), do: "Source HTTP #{status}: #{inspect(body)}"
  defp format_error(other), do: inspect(other)

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
              where the runtime lives — <span class="text-zinc-700">local, remote, or fleet</span>.
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
                    <th>User</th>
                    <th>Branch</th>
                    <th>Status</th>
                    <th class="text-right pr-4">Actions</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for ws <- host.workspaces do %>
                    <tr class="border-t hover:bg-zinc-50/50">
                      <td class="py-2 px-4">
                        <.link
                          navigate={~p"/workspaces/#{ws.id}?#{[host: host.id]}"}
                          class="text-blue-700 hover:underline font-medium"
                        >
                          {ws.name}
                        </.link>
                      </td>
                      <td class="text-zinc-600">{ws.user}</td>
                      <td class="font-mono text-xs text-zinc-600">{ws.branch}</td>
                      <td><span class={status_class(ws.status)}>{ws.status}</span></td>
                      <td class="text-right pr-4 space-x-2">
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
  defp mode_class(:fleet), do: "bg-amber-50 text-amber-700 border border-amber-200"
  defp mode_class(_), do: "bg-zinc-50 text-zinc-600 border border-zinc-200"

  defp status_class(:running), do: "text-green-700"
  defp status_class(:stopped), do: "text-zinc-500"
  defp status_class(_), do: "text-amber-700"
end
