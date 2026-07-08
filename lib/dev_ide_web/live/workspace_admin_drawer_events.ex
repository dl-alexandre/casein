defmodule DevIdeWeb.WorkspaceAdminDrawerEvents do
  @moduledoc false

  # Header workspace-admin drawer state + events for WorkspaceLive.Show.
  # Ports the dashboard's create/start/stop/attach_folder/toggle_all actions
  # into the cockpit so Stage 4c can retire WorkspaceLive.Dashboard.

  import Phoenix.Component
  import Phoenix.LiveView, only: [connected?: 1, put_flash: 3, push_navigate: 2]

  alias DevIDE.Workspaces
  alias DevIDE.Workspaces.SessionSummary
  alias DevIdeWeb.Plugs.ForwardAuth
  alias DevIdeWeb.WorkspaceRoutes

  @doc "Drawer defaults piped from Show mount."
  def mount(socket) do
    user = socket.assigns[:current_user]
    is_admin = ForwardAuth.admin?(user)

    socket
    |> assign(:admin_drawer_open, false)
    |> assign(:admin_is_admin, is_admin)
    # Admins default to cross-user view for summary/list; non-admins stay scoped.
    |> assign(:admin_show_all, is_admin)
    |> assign(:admin_error, nil)
    |> assign(:admin_create_open, false)
    |> assign(:admin_create_fields, Workspaces.create_form_fields())
    |> assign(:admin_create_form, initial_create_form(user))
    |> assign(:admin_folder_form, folder_form())
    |> assign(:admin_workspaces, [])
  end

  @doc "`?drawer=admin` deep link — one-shot like notifications."
  def apply_drawer_param(socket, %{"drawer" => "admin"}) do
    if socket.assigns[:admin_drawer_open], do: socket, else: open(socket)
  end

  def apply_drawer_param(socket, _params), do: socket

  def open(socket) do
    socket
    |> assign(:admin_drawer_open, true)
    |> then(fn s -> if connected?(s), do: load_workspaces(s), else: s end)
  end

  def close(socket), do: assign(socket, :admin_drawer_open, false)

  def toggle(socket) do
    if socket.assigns.admin_drawer_open, do: close(socket), else: open(socket)
  end

  def handle_event("workspace_admin:toggle", _params, socket) do
    {:noreply, toggle(socket)}
  end

  def handle_event("workspace_admin:close", _params, socket) do
    {:noreply, close(socket)}
  end

  def handle_event("workspace_admin:create_toggle", _params, socket) do
    {:noreply, assign(socket, :admin_create_open, not socket.assigns.admin_create_open)}
  end

  def handle_event("workspace_admin:toggle_all", _params, socket) do
    if socket.assigns.admin_is_admin do
      show_all = not socket.assigns.admin_show_all

      {:noreply,
       socket
       |> assign(:admin_show_all, show_all)
       |> load_workspaces()}
    else
      {:noreply, assign(socket, :admin_error, "Admin only.")}
    end
  end

  def handle_event("workspace_admin:create", params, socket) do
    attrs =
      params
      |> Map.take(["name", "user", "type"])
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
      |> Map.new()

    case Workspaces.create(attrs, auth(socket)) do
      {:ok, _ws} ->
        {:noreply,
         socket
         |> assign(:admin_error, nil)
         |> assign(:admin_create_open, false)
         |> load_workspaces()
         |> put_flash(:info, "Workspace created.")}

      {:error, reason} ->
        {:noreply, assign(socket, :admin_error, format_error(reason))}
    end
  end

  def handle_event("workspace_admin:attach_folder", %{"folder" => %{"path" => path}}, socket) do
    {:noreply, open_folder(socket, path)}
  end

  def handle_event("workspace_admin:attach_folder", _params, socket) do
    {:noreply, assign(socket, :admin_error, "Folder path is not a directory.")}
  end

  def handle_event("workspace_admin:start", %{"id" => id}, socket) when is_binary(id) do
    case Workspaces.start(id, auth(socket)) do
      {:ok, _} ->
        {:noreply, socket |> assign(:admin_error, nil) |> load_workspaces()}

      {:error, reason} ->
        {:noreply, assign(socket, :admin_error, format_error(reason))}
    end
  end

  def handle_event("workspace_admin:stop", %{"id" => id}, socket) when is_binary(id) do
    case Workspaces.stop(id, auth(socket)) do
      {:ok, _} ->
        {:noreply, socket |> assign(:admin_error, nil) |> load_workspaces()}

      {:error, reason} ->
        {:noreply, assign(socket, :admin_error, format_error(reason))}
    end
  end

  def handle_event("workspace_admin:" <> _, _params, socket), do: {:noreply, socket}

  @doc "Whether a workspace summary row is visible given admin show-all."
  def summary_visible?(summary, socket) do
    summary.id == socket.assigns.workspace.id or
      socket.assigns[:admin_show_all] == true or
      Workspaces.viewer_owns_workspace?(
        %{user: summary.user},
        socket.assigns[:current_user] || %{}
      )
  end

  defp open_folder(socket, path) when is_binary(path) do
    case Workspaces.attach_folder(path) do
      {:ok, ws} ->
        push_navigate(socket, to: WorkspaceRoutes.workspace_path(ws, "local"))

      {:error, reason} ->
        socket
        |> assign(:admin_folder_form, folder_form(path))
        |> assign(:admin_error, format_attach_error(reason))
    end
  end

  defp load_workspaces(socket) do
    case Workspaces.list(list_opts(socket), auth(socket)) do
      {:ok, list} ->
        workspaces =
          list
          |> filter_visible(socket)
          |> SessionSummary.build_many()

        socket
        |> assign(:admin_workspaces, workspaces)
        |> assign(:admin_error, nil)

      {:error, reason} ->
        socket
        |> assign(:admin_workspaces, [])
        |> assign(:admin_error, format_error(reason))
    end
  end

  defp filter_visible(workspaces, socket) do
    if ForwardAuth.enabled?() and not socket.assigns.admin_show_all do
      Enum.filter(workspaces, &Workspaces.viewer_owns_workspace?(&1, socket.assigns.current_user))
    else
      workspaces
    end
  end

  defp list_opts(%{assigns: %{admin_show_all: true}}), do: [all: true]
  defp list_opts(_socket), do: []

  defp auth(socket), do: get_in(socket.assigns, [:current_user, :email])

  defp initial_create_form(user) do
    fields = Workspaces.create_form_fields()
    user_id = if is_map(user), do: Map.get(user, :id) || Map.get(user, "id")

    %{}
    |> Map.put_new("name", "")
    |> Map.put_new("user", if(:user in fields, do: user_id, else: nil))
    |> Map.put_new("type", if(:type in fields, do: "v3", else: nil))
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp folder_form(path \\ "") do
    to_form(%{"path" => path}, as: :folder)
  end

  defp format_error({:transport, %{reason: :econnrefused}}),
    do: "Workspace source is not reachable."

  defp format_error({:transport, reason}), do: "Transport error: #{inspect(reason)}"
  defp format_error({:http, status, body}), do: "Source HTTP #{status}: #{inspect(body)}"
  defp format_error(other), do: inspect(other)

  defp format_attach_error(reason) do
    case reason do
      :not_a_directory -> "Folder path is not a directory."
      :outside_allowed_roots -> "Folder path is outside the allowed roots."
      other -> "Attach failed: #{inspect(other)}"
    end
  end
end
