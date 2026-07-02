defmodule DevIdeWeb.Plugs.ForwardAuthTest do
  use DevIDE.TestCase, async: false

  import Plug.Test
  import Plug.Conn

  alias DevIdeWeb.Plugs.{AssignCurrentUser, ForwardAuth}

  setup do
    prev = Application.get_env(:dev_ide, :forward_auth)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:dev_ide, :forward_auth)
        val -> Application.put_env(:dev_ide, :forward_auth, val)
      end
    end)

    :ok
  end

  defp build_conn(headers) do
    headers
    |> Enum.reduce(conn(:get, "/"), fn {k, v}, c -> put_req_header(c, k, v) end)
    |> Plug.Test.init_test_session(%{})
  end

  describe "user_from_email/1" do
    test "derives the manager-style username: email local part, lowercased" do
      user = ForwardAuth.user_from_email("dalexandre@example.com")

      assert user.username == "dalexandre"
      assert user.id == "dalexandre"
      assert user.email == "dalexandre@example.com"
      assert user.role == :owner
    end

    test "lowercases mixed-case emails (matches manager normalizeUser)" do
      user = ForwardAuth.user_from_email("Foo.Bar@EXAMPLE.COM")

      assert user.username == "foo.bar"
      assert user.email == "foo.bar@example.com"
    end
  end

  describe "admins" do
    setup do
      prev = Application.get_env(:dev_ide, :admins)
      prev_env = System.get_env("DEV_IDE_ADMINS")

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:dev_ide, :admins)
          val -> Application.put_env(:dev_ide, :admins, val)
        end

        case prev_env do
          nil -> System.delete_env("DEV_IDE_ADMINS")
          val -> System.put_env("DEV_IDE_ADMINS", val)
        end
      end)

      :ok
    end

    test "user_from_email/1 tags emails in the admins list with role :admin" do
      Application.put_env(:dev_ide, :admins, ["boss@example.com"])

      assert ForwardAuth.user_from_email("boss@example.com").role == :admin
      assert ForwardAuth.user_from_email("dev@example.com").role == :owner
    end

    test "admins/0 lowercases the configured list" do
      Application.put_env(:dev_ide, :admins, ["Foo@Bar.com", "baz@qux.com"])
      assert ForwardAuth.admins() == ["foo@bar.com", "baz@qux.com"]
    end

    test "admins/0 is empty when nothing is configured" do
      Application.delete_env(:dev_ide, :admins)
      System.delete_env("DEV_IDE_ADMINS")
      assert ForwardAuth.admins() == []
    end

    test "admin?/1 reads the role, tolerates non-identity input" do
      assert ForwardAuth.admin?(%{role: :admin})
      refute ForwardAuth.admin?(%{role: :owner})
      refute ForwardAuth.admin?(%{})
      refute ForwardAuth.admin?(nil)
    end
  end

  describe "call/2 with forward-auth enabled" do
    setup do
      Application.put_env(:dev_ide, :forward_auth, true)
      :ok
    end

    test "assigns the derived identity and stashes it in the session" do
      conn =
        [{"x-auth-request-email", "rgomez@example.com"}]
        |> build_conn()
        |> ForwardAuth.call([])

      refute conn.halted
      assert conn.assigns.current_user.username == "rgomez"
      assert get_session(conn, "current_user").username == "rgomez"
    end

    test "rejects a request missing the header with 401" do
      conn = build_conn([]) |> ForwardAuth.call([])

      assert conn.halted
      assert conn.status == 401
    end

    test "rejects an empty header value with 401" do
      conn =
        [{"x-auth-request-email", ""}]
        |> build_conn()
        |> ForwardAuth.call([])

      assert conn.halted
      assert conn.status == 401
    end
  end

  describe "call/2 with forward-auth disabled" do
    test "ignores the header, falls back to the static identity, still writes the session" do
      Application.put_env(:dev_ide, :forward_auth, false)

      conn =
        [{"x-auth-request-email", "someone@example.com"}]
        |> build_conn()
        |> ForwardAuth.call([])

      refute conn.halted
      assert conn.assigns.current_user == AssignCurrentUser.current_user()
      assert get_session(conn, "current_user") == conn.assigns.current_user
    end
  end

  describe "AssignCurrentUser.from_session/1" do
    test "reads the identity ForwardAuth stashed in the session" do
      user = %{id: "x", username: "x", email: "x@example.com", role: :owner}
      assert AssignCurrentUser.from_session(%{"current_user" => user}) == user
    end

    test "falls back to the static identity when the session has none" do
      assert AssignCurrentUser.from_session(%{}) == AssignCurrentUser.current_user()
    end
  end
end
