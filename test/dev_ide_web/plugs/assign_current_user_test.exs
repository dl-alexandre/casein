defmodule DevIdeWeb.Plugs.AssignCurrentUserTest do
  use DevIDE.TestCase, async: false

  import Plug.Test

  alias DevIdeWeb.Plugs.AssignCurrentUser

  @default_user %{id: "dev", username: "dev", email: "dev@local", role: :user}

  setup do
    previous_user = Application.get_env(:dev_ide, :current_user)
    Application.delete_env(:dev_ide, :current_user)

    on_exit(fn ->
      case previous_user do
        nil -> Application.delete_env(:dev_ide, :current_user)
        user -> Application.put_env(:dev_ide, :current_user, user)
      end
    end)

    :ok
  end

  test "from_session/1 returns the identity stored in the session" do
    user = %{"id" => "person@example.com", "email" => "person@example.com"}

    assert AssignCurrentUser.from_session(%{"current_user" => user}) == user
  end

  test "from_session/1 falls back to the static user when session identity is absent" do
    assert AssignCurrentUser.from_session(%{}) == @default_user
    assert AssignCurrentUser.from_session(nil) == @default_user
  end

  test "current_user/0 returns its default identity" do
    assert AssignCurrentUser.current_user() == @default_user
  end

  test "current_user/0 returns the application environment override" do
    override = %{id: "test-user", email: "test@example.com", role: :admin}
    Application.put_env(:dev_ide, :current_user, override)

    assert AssignCurrentUser.current_user() == override
  end

  test "call/2 assigns the static current user when no session identity is present" do
    conn =
      :get
      |> conn("/")
      |> AssignCurrentUser.call([])

    refute conn.halted
    assert conn.assigns.current_user == @default_user
  end

  test "call/2 uses current_user/0 rather than the identity stored in the session" do
    session_user = %{"id" => "session-user", "email" => "session@example.com"}
    override = %{id: "configured-user", email: "configured@example.com", role: :user}
    Application.put_env(:dev_ide, :current_user, override)

    conn =
      :get
      |> conn("/")
      |> init_test_session(%{"current_user" => session_user})
      |> AssignCurrentUser.call([])

    refute conn.halted
    assert conn.assigns.current_user == override
  end
end
