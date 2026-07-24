defmodule Casein.Integrations.Manager.ClientAuthHeadersTest do
  use Casein.TestCase, async: false

  alias Casein.Integrations.Manager.Client

  defp json(conn, status, payload) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(payload))
  end

  test "nil auth with no static config sends no auth header" do
    prev = Application.get_env(:dev_ide, :manager_user_email)
    env_prev = System.get_env("DEV_IDE_DEVBOX_USER_EMAIL")
    Application.delete_env(:dev_ide, :manager_user_email)
    System.delete_env("DEV_IDE_DEVBOX_USER_EMAIL")

    Req.Test.stub(Client, fn conn ->
      assert Plug.Conn.get_req_header(conn, "x-auth-request-email") == []
      json(conn, 200, [])
    end)

    try do
      assert {:ok, []} = Client.list([], nil)
    after
      restore(:manager_user_email, prev)
      if env_prev, do: System.put_env("DEV_IDE_DEVBOX_USER_EMAIL", env_prev)
    end
  end

  test "nil auth falls back to the static :manager_user_email config" do
    prev = Application.get_env(:dev_ide, :manager_user_email)
    Application.put_env(:dev_ide, :manager_user_email, "static@example.com")

    Req.Test.stub(Client, fn conn ->
      assert Plug.Conn.get_req_header(conn, "x-auth-request-email") == ["static@example.com"]
      json(conn, 200, [])
    end)

    try do
      assert {:ok, []} = Client.list([], nil)
    after
      restore(:manager_user_email, prev)
    end
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, value), do: Application.put_env(:dev_ide, key, value)
end
