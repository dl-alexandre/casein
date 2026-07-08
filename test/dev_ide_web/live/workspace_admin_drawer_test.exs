defmodule DevIdeWeb.WorkspaceAdminDrawerTest do
  use DevIDE.TestCase, async: false

  import Phoenix.LiveViewTest

  alias DevIdeWeb.WorkspaceAdminDrawer
  alias DevIdeWeb.WorkspaceAdminDrawerEvents

  setup do
    prev_forward = Application.get_env(:dev_ide, :forward_auth)

    on_exit(fn ->
      if is_nil(prev_forward),
        do: Application.delete_env(:dev_ide, :forward_auth),
        else: Application.put_env(:dev_ide, :forward_auth, prev_forward)
    end)

    :ok
  end

  test "admin_bell renders toggle control" do
    html = render_component(&WorkspaceAdminDrawer.admin_bell/1, id: "admin-bell", open: false)

    assert html =~ ~s(id="admin-bell")
    assert html =~ ~s(phx-click="workspace_admin:toggle")
    assert html =~ "Workspace admin"
  end

  test "admin_drawer renders create, attach, and start/stop controls" do
    folder_form = Phoenix.Component.to_form(%{"path" => ""}, as: :folder)

    html =
      render_component(&WorkspaceAdminDrawer.admin_drawer/1,
        open: true,
        is_admin: true,
        show_all: true,
        error: nil,
        create_open: true,
        create_fields: [:name, :user],
        create_form: %{"name" => "", "user" => "alice"},
        folder_form: folder_form,
        workspaces: [
          %{id: "ws-1", name: "alpha", status: :running},
          %{id: "ws-2", name: "beta", status: :stopped}
        ],
        current_workspace_id: "ws-1"
      )

    assert html =~ ~s(id="workspace-admin-drawer")
    assert html =~ ~s(phx-submit="workspace_admin:attach_folder")
    assert html =~ ~s(phx-submit="workspace_admin:create")
    assert html =~ ~s(phx-click="workspace_admin:toggle_all")
    assert html =~ ~s(phx-click="workspace_admin:stop")
    assert html =~ ~s(phx-value-id="ws-1")
    assert html =~ ~s(phx-click="workspace_admin:start")
    assert html =~ ~s(phx-value-id="ws-2")
    assert html =~ "alpha"
    assert html =~ "beta"
  end

  test "toggle_all is denied for non-admins" do
    socket =
      %Phoenix.LiveView.Socket{}
      |> Map.put(:assigns, Map.put(%Phoenix.LiveView.Socket{}.assigns, :__changed__, %{}))
      |> Phoenix.Component.assign(:admin_drawer_open, true)
      |> Phoenix.Component.assign(:admin_is_admin, false)
      |> Phoenix.Component.assign(:admin_show_all, false)
      |> Phoenix.Component.assign(:admin_error, nil)
      |> Phoenix.Component.assign(:admin_create_open, false)
      |> Phoenix.Component.assign(:admin_create_fields, [])
      |> Phoenix.Component.assign(:admin_create_form, %{})
      |> Phoenix.Component.assign(
        :admin_folder_form,
        Phoenix.Component.to_form(%{"path" => ""}, as: :folder)
      )
      |> Phoenix.Component.assign(:admin_workspaces, [])
      |> Phoenix.Component.assign(:current_user, %{id: "bob", email: "bob@example.com"})
      |> Phoenix.Component.assign(:workspace, %{id: "ws-1"})

    assert {:noreply, socket} =
             WorkspaceAdminDrawerEvents.handle_event("workspace_admin:toggle_all", %{}, socket)

    assert socket.assigns.admin_error == "Admin only."
    refute socket.assigns.admin_show_all
  end

  test "summary_visible? allows all when admin_show_all is true" do
    socket = %{
      assigns: %{
        workspace: %{id: "ws-current"},
        admin_show_all: true,
        current_user: %{id: "alice"}
      }
    }

    assert WorkspaceAdminDrawerEvents.summary_visible?(
             %{id: "other", user: "bob"},
             socket
           )
  end

  test "summary_visible? scopes to owner when show_all is false" do
    socket = %{
      assigns: %{
        workspace: %{id: "ws-current"},
        admin_show_all: false,
        current_user: %{id: "alice", email: "alice@example.com"}
      }
    }

    assert WorkspaceAdminDrawerEvents.summary_visible?(
             %{id: "ws-current", user: "bob"},
             socket
           )

    assert WorkspaceAdminDrawerEvents.summary_visible?(
             %{id: "alice-ws", user: "alice"},
             socket
           )

    refute WorkspaceAdminDrawerEvents.summary_visible?(
             %{id: "bob-ws", user: "bob"},
             socket
           )
  end

  test "toggle_all flips show_all for admins without forward-auth list" do
    Application.put_env(:dev_ide, :forward_auth, false)

    socket =
      %Phoenix.LiveView.Socket{}
      |> Map.put(:assigns, Map.put(%Phoenix.LiveView.Socket{}.assigns, :__changed__, %{}))
      |> Phoenix.Component.assign(:admin_drawer_open, true)
      |> Phoenix.Component.assign(:admin_is_admin, true)
      |> Phoenix.Component.assign(:admin_show_all, true)
      |> Phoenix.Component.assign(:admin_error, nil)
      |> Phoenix.Component.assign(:admin_create_open, false)
      |> Phoenix.Component.assign(:admin_create_fields, [])
      |> Phoenix.Component.assign(:admin_create_form, %{})
      |> Phoenix.Component.assign(
        :admin_folder_form,
        Phoenix.Component.to_form(%{"path" => ""}, as: :folder)
      )
      |> Phoenix.Component.assign(:admin_workspaces, [])
      |> Phoenix.Component.assign(:current_user, %{
        id: "ops",
        email: "ops@example.com",
        role: :admin
      })
      |> Phoenix.Component.assign(:workspace, %{id: "ws-1"})

    assert {:noreply, socket} =
             WorkspaceAdminDrawerEvents.handle_event("workspace_admin:toggle_all", %{}, socket)

    refute socket.assigns.admin_show_all
    assert socket.assigns.admin_error == nil
  end
end
