defmodule DevIdeWeb.Plugs.ForwardAuthTest do
  use ExUnit.Case, async: false

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
      user = ForwardAuth.user_from_email("dalexandre@milcgroup.com")

      assert user.username == "dalexandre"
      assert user.id == "dalexandre"
      assert user.email == "dalexandre@milcgroup.com"
      assert user.role == :owner
    end

    test "lowercases mixed-case emails (matches manager normalizeUser)" do
      user = ForwardAuth.user_from_email("Foo.Bar@MILCGROUP.com")

      assert user.username == "foo.bar"
      assert user.email == "foo.bar@milcgroup.com"
    end
  end

  describe "call/2 with forward-auth enabled" do
    setup do
      Application.put_env(:dev_ide, :forward_auth, true)
      :ok
    end

    test "assigns the derived identity and stashes it in the session" do
      conn =
        [{"x-auth-request-email", "rgomez@milcgroup.com"}]
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
        [{"x-auth-request-email", "someone@milcgroup.com"}]
        |> build_conn()
        |> ForwardAuth.call([])

      refute conn.halted
      assert conn.assigns.current_user == AssignCurrentUser.current_user()
      assert get_session(conn, "current_user") == conn.assigns.current_user
    end
  end

  describe "AssignCurrentUser.from_session/1" do
    test "reads the identity ForwardAuth stashed in the session" do
      user = %{id: "x", username: "x", email: "x@milcgroup.com", role: :owner}
      assert AssignCurrentUser.from_session(%{"current_user" => user}) == user
    end

    test "falls back to the static identity when the session has none" do
      assert AssignCurrentUser.from_session(%{}) == AssignCurrentUser.current_user()
    end
  end
end
