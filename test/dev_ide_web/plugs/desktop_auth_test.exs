defmodule DevIdeWeb.Plugs.DesktopAuthTest do
  use DevIDE.TestCase, async: false

  import Plug.Conn
  import Plug.Test

  alias DevIdeWeb.Plugs.DesktopAuth

  setup do
    previous_mode = Application.get_env(:dev_ide, :desktop_mode)
    previous_token = Application.get_env(:dev_ide, :desktop_launch_token)

    Application.put_env(:dev_ide, :desktop_mode, true)
    Application.put_env(:dev_ide, :desktop_launch_token, String.duplicate("a", 48))

    on_exit(fn ->
      restore(:desktop_mode, previous_mode)
      restore(:desktop_launch_token, previous_token)
    end)

    :ok
  end

  test "exchanges a valid launch token for a signed browser session" do
    conn =
      :get
      |> desktop_conn("/?desktop_token=#{String.duplicate("a", 48)}")
      |> DesktopAuth.call([])

    assert conn.halted
    assert conn.status == 302
    assert get_resp_header(conn, "location") == ["/"]
    assert get_session(conn, "current_user").id == "desktop"
  end

  test "rejects a request with no launch token or desktop session" do
    conn = :get |> desktop_conn("/") |> DesktopAuth.call([])

    assert conn.halted
    assert conn.status == 401
  end

  test "allows the loopback health probe without granting cockpit access" do
    conn = :get |> desktop_conn("/healthz") |> DesktopAuth.call([])

    refute conn.halted
    refute Map.has_key?(conn.assigns, :current_user)
  end

  test "rejects non-local host headers before checking credentials" do
    conn =
      :get
      |> desktop_conn("/?desktop_token=#{String.duplicate("a", 48)}")
      |> Map.put(:host, "rebinding.invalid")
      |> DesktopAuth.call([])

    assert conn.halted
    assert conn.status == 421
  end

  test "accepts a previously issued desktop session without a token" do
    conn =
      :get
      |> desktop_conn("/", %{"current_user" => %{id: "desktop"}})
      |> DesktopAuth.call([])

    refute conn.halted
    assert conn.assigns.current_user.id == "desktop"
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, value), do: Application.put_env(:dev_ide, key, value)

  defp desktop_conn(method, path, session \\ %{}) do
    method
    |> conn(path)
    |> Map.put(:host, "localhost")
    |> init_test_session(session)
  end
end
