defmodule CaseinWeb.AssignCurrentUserHookTest do
  use Casein.TestCase, async: true

  alias CaseinWeb.AssignCurrentUserHook

  defp socket(assigns \\ %{}) do
    %Phoenix.LiveView.Socket{
      endpoint: CaseinWeb.Endpoint,
      assigns: Map.merge(%{__changed__: %{}}, assigns)
    }
  end

  test "assign_new keeps an existing socket assign" do
    user = %{id: "socket-user", username: "socket", email: "socket@example.com", role: :owner}

    assert {:cont, socket} =
             AssignCurrentUserHook.on_mount(
               :default,
               %{},
               %{"current_user" => %{}},
               socket(%{current_user: user})
             )

    assert socket.assigns.current_user == user
  end

  test "assign_new resolves current_user from the session when absent on the socket" do
    user = %{id: "session-user", username: "session", email: "session@example.com", role: :owner}

    assert {:cont, socket} =
             AssignCurrentUserHook.on_mount(:default, %{}, %{"current_user" => user}, socket())

    assert socket.assigns.current_user == user
  end
end
