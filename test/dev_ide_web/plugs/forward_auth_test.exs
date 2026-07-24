defmodule CaseinWeb.Plugs.ForwardAuthTest do
  use Casein.TestCase, async: false

  import Plug.Test
  import Plug.Conn

  alias CaseinWeb.Plugs.{AssignCurrentUser, ForwardAuth}

  setup do
    prev = Application.get_env(:casein, :forward_auth)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:casein, :forward_auth)
        val -> Application.put_env(:casein, :forward_auth, val)
      end
    end)

    :ok
  end

  defp build_conn(headers, method \\ :get) do
    headers
    |> Enum.reduce(conn(method, "/"), fn {k, v}, c -> put_req_header(c, k, v) end)
    |> Plug.Test.init_test_session(%{})
  end

  describe "user_from_email/1" do
    test "derives the manager-style username: email local part, lowercased" do
      user = ForwardAuth.user_from_email("dalexandre@example.com")

      assert user.username == "dalexandre"
      assert user.id == "dalexandre"
      assert user.email == "dalexandre@example.com"
      assert user.role == :user
    end

    test "lowercases mixed-case emails (matches manager normalizeUser)" do
      user = ForwardAuth.user_from_email("Foo.Bar@EXAMPLE.COM")

      assert user.username == "foo.bar"
      assert user.email == "foo.bar@example.com"
    end

    test "user_from_email/1 never elevates via the legacy admins list" do
      Application.put_env(:casein, :admins, ["boss@example.com"])
      on_exit(fn -> Application.delete_env(:casein, :admins) end)

      assert ForwardAuth.user_from_email("boss@example.com").role == :user
      assert ForwardAuth.user_from_email("dev@example.com").role == :user
    end
  end

  describe "admins (legacy list, no privileges)" do
    setup do
      prev = Application.get_env(:casein, :admins)
      prev_env = System.get_env("DEV_IDE_ADMINS")

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:casein, :admins)
          val -> Application.put_env(:casein, :admins, val)
        end

        case prev_env do
          nil -> System.delete_env("DEV_IDE_ADMINS")
          val -> System.put_env("DEV_IDE_ADMINS", val)
        end
      end)

      :ok
    end

    test "admins/0 lowercases the configured list" do
      Application.put_env(:casein, :admins, ["Foo@Bar.com", "baz@qux.com"])
      assert ForwardAuth.admins() == ["foo@bar.com", "baz@qux.com"]
    end

    test "admins/0 is empty when nothing is configured" do
      Application.delete_env(:casein, :admins)
      System.delete_env("DEV_IDE_ADMINS")
      assert ForwardAuth.admins() == []
    end

    test "admin?/1 is true for any authenticated identity, false otherwise" do
      assert ForwardAuth.admin?(%{id: "boss", email: "boss@example.com", role: :user})
      assert ForwardAuth.admin?(%{id: "peer", email: "peer@example.com", role: :user})
      refute ForwardAuth.admin?(%{})
      refute ForwardAuth.admin?(nil)
    end
  end

  describe "call/2 with forward-auth enabled" do
    setup do
      Application.put_env(:casein, :forward_auth, true)
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

    test "rejects OPTIONS with 405 and does not trust X-Auth-Request-Email" do
      conn =
        [{"x-auth-request-email", "victim@example.com"}]
        |> build_conn(:options)
        |> ForwardAuth.call([])

      assert conn.halted
      assert conn.status == 405
      refute Map.has_key?(conn.assigns, :current_user)
      assert get_session(conn, "current_user") == nil
    end
  end

  describe "call/2 with forward-auth disabled" do
    test "ignores the header, falls back to the static identity, still writes the session" do
      Application.put_env(:casein, :forward_auth, false)

      conn =
        [{"x-auth-request-email", "someone@example.com"}]
        |> build_conn()
        |> ForwardAuth.call([])

      refute conn.halted
      assert conn.assigns.current_user == AssignCurrentUser.current_user()
      assert get_session(conn, "current_user") == conn.assigns.current_user
    end
  end

  describe "assert_safe_listener_bind!/0" do
    setup do
      prev_forward = Application.get_env(:casein, :forward_auth)
      prev_endpoint = Application.get_env(:casein, CaseinWeb.Endpoint)

      on_exit(fn ->
        case prev_forward do
          nil -> Application.delete_env(:casein, :forward_auth)
          val -> Application.put_env(:casein, :forward_auth, val)
        end

        case prev_endpoint do
          nil -> Application.delete_env(:casein, CaseinWeb.Endpoint)
          val -> Application.put_env(:casein, CaseinWeb.Endpoint, val)
        end
      end)

      :ok
    end

    test "passes when forward-auth is disabled" do
      Application.put_env(:casein, :forward_auth, false)
      Application.put_env(:casein, CaseinWeb.Endpoint, http: [ip: {0, 0, 0, 0}])

      assert :ok = ForwardAuth.assert_safe_listener_bind!()
    end

    test "passes when forward-auth is enabled on loopback" do
      Application.put_env(:casein, :forward_auth, true)
      Application.put_env(:casein, CaseinWeb.Endpoint, http: [ip: {127, 0, 0, 1}])

      assert :ok = ForwardAuth.assert_safe_listener_bind!()
      assert ForwardAuth.listener_bind_safe?()
    end

    test "raises when forward-auth is enabled outside loopback (fail closed in all envs)" do
      Application.put_env(:casein, :forward_auth, true)
      Application.put_env(:casein, CaseinWeb.Endpoint, http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}])

      assert_raise RuntimeError, ~r/Forward-auth is enabled/, fn ->
        ForwardAuth.assert_safe_listener_bind!()
      end

      refute ForwardAuth.listener_bind_safe?()
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
