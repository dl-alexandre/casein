defmodule DevIdeWeb.WorkspaceLive.Index do
  use DevIdeWeb, :live_view

  alias DevIDE.Workspaces
  alias DevIdeWeb.Plugs.AssignCurrentUser

  @refresh_ms 5_000

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_ms, :refresh)

    user = AssignCurrentUser.from_session(session)

    {:ok,
     socket
     |> assign(:page_title, "Workspaces")
     |> assign(:current_user, user)
     |> assign(:error, nil)
     |> assign(:manager_url, DevIDE.Devbox.ManagerClient.base_url())
     |> assign(:form, %{"name" => "", "user" => user.id, "type" => "v3"})
     |> load_workspaces()}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load_workspaces(socket)}

  @impl true
  def handle_event("start", %{"id" => id}, socket) do
    _ = Workspaces.start(id)
    {:noreply, load_workspaces(socket)}
  end

  def handle_event("stop", %{"id" => id}, socket) do
    _ = Workspaces.stop(id)
    {:noreply, load_workspaces(socket)}
  end

  def handle_event("create", params, socket) do
    attrs = %{name: params["name"], user: params["user"], type: params["type"] || "v3"}

    case Workspaces.create(attrs) do
      {:ok, _ws} -> {:noreply, socket |> assign(:error, nil) |> load_workspaces()}
      {:error, reason} -> {:noreply, assign(socket, :error, format_error(reason))}
    end
  end

  defp load_workspaces(socket) do
    case Workspaces.list() do
      {:ok, list} -> assign(socket, workspaces: list, error: nil)
      {:error, reason} -> assign(socket, workspaces: [], error: format_error(reason))
    end
  end

  defp format_error({:transport, %{reason: :econnrefused}}),
    do: "Manager is not reachable. Is the milc-devbox manager running?"

  defp format_error({:transport, reason}), do: "Transport error: #{inspect(reason)}"
  defp format_error({:http, status, body}), do: "Manager HTTP #{status}: #{inspect(body)}"
  defp format_error(other), do: inspect(other)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-5xl p-6 space-y-6">
      <header class="flex items-center justify-between">
        <h1 class="text-2xl font-semibold">Workspaces</h1>
        <span class="text-xs text-zinc-500 font-mono">manager: {@manager_url}</span>
      </header>

      <%= if @error do %>
        <div class="rounded border border-red-300 bg-red-50 p-3 text-sm text-red-800">
          {@error}
        </div>
      <% end %>

      <section class="rounded border border-zinc-200 p-4">
        <h2 class="mb-2 font-medium">Create workspace</h2>
        <.form for={%{}} as={:ws} phx-submit="create" class="flex flex-wrap gap-2 items-end">
          <label class="text-sm">
            Name
            <input name="name" value={@form["name"]} class="block border rounded px-2 py-1" required />
          </label>
          <label class="text-sm">
            User
            <input name="user" value={@form["user"]} class="block border rounded px-2 py-1" required />
          </label>
          <label class="text-sm">
            Type
            <select name="type" class="block border rounded px-2 py-1">
              <option value="v3" selected>v3</option>
              <option value="legacy">legacy</option>
            </select>
          </label>
          <button class="rounded bg-zinc-900 text-white px-3 py-1.5 text-sm">Create</button>
        </.form>
      </section>

      <section>
        <table class="w-full text-sm">
          <thead class="text-left text-zinc-500">
            <tr>
              <th class="py-2">Name</th>
              <th>User</th>
              <th>Branch</th>
              <th>Status</th>
              <th>Type</th>
              <th class="text-right">Actions</th>
            </tr>
          </thead>
          <tbody>
            <%= for ws <- @workspaces do %>
              <tr class="border-t">
                <td class="py-2">
                  <.link navigate={~p"/workspaces/#{ws.id}"} class="text-blue-700 hover:underline">
                    {ws.name}
                  </.link>
                </td>
                <td>{ws.user}</td>
                <td class="font-mono text-xs">{ws.branch}</td>
                <td><span class={status_class(ws.status)}>{ws.status}</span></td>
                <td>{ws.type}</td>
                <td class="text-right space-x-2">
                  <%= if ws.status == :running do %>
                    <button
                      phx-click="stop"
                      phx-value-id={ws.id}
                      class="text-xs px-2 py-1 rounded border"
                    >
                      stop
                    </button>
                  <% else %>
                    <button
                      phx-click="start"
                      phx-value-id={ws.id}
                      class="text-xs px-2 py-1 rounded border"
                    >
                      start
                    </button>
                  <% end %>
                </td>
              </tr>
            <% end %>
            <%= if @workspaces == [] do %>
              <tr>
                <td colspan="6" class="py-6 text-center text-zinc-400">No workspaces.</td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </section>
    </div>
    """
  end

  defp status_class(:running), do: "text-green-700"
  defp status_class(:stopped), do: "text-zinc-500"
  defp status_class(_), do: "text-amber-700"
end
