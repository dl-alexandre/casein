defmodule DevIDE.Previews.EnvPortsTest do
  use ExUnit.Case, async: false

  alias DevIDE.Previews.EnvPorts

  setup do
    prev_range = Application.get_env(:dev_ide, :preview_env_port_range)
    prev_loopback = Application.get_env(:dev_ide, :preview_loopback_port)
    prev_port = System.get_env("PORT")

    on_exit(fn ->
      restore_env(:preview_env_port_range, prev_range)
      restore_env(:preview_loopback_port, prev_loopback)

      if prev_port,
        do: System.put_env("PORT", prev_port),
        else: System.delete_env("PORT")
    end)

    :ok
  end

  test "port_range reads configured inclusive bounds" do
    Application.put_env(:dev_ide, :preview_env_port_range, {41_010, 41_020})
    assert EnvPorts.port_range() == {41_010, 41_020}
  end

  test "port_range falls back when config is invalid" do
    Application.put_env(:dev_ide, :preview_env_port_range, :invalid)
    assert EnvPorts.port_range() == {41_000, 41_099}
  end

  test "preview_env_port? is true inside the ephemeral range" do
    assert EnvPorts.preview_env_port?(41_000)
    assert EnvPorts.preview_env_port?(41_099)
    refute EnvPorts.preview_env_port?(40_999)
    refute EnvPorts.preview_env_port?(41_100)
    refute EnvPorts.preview_env_port?("41000")
  end

  test "current_port prefers preview_loopback_port then PORT env" do
    Application.put_env(:dev_ide, :preview_loopback_port, 41_055)
    assert EnvPorts.current_port() == 41_055

    Application.delete_env(:dev_ide, :preview_loopback_port)
    System.put_env("PORT", "4123")
    assert EnvPorts.current_port() == 4123
  end

  test "preview_env_instance? reflects whether current port is ephemeral" do
    Application.put_env(:dev_ide, :preview_loopback_port, 41_042)
    assert EnvPorts.preview_env_instance?()

    Application.put_env(:dev_ide, :preview_loopback_port, 4000)
    refute EnvPorts.preview_env_instance?()
  end

  defp restore_env(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore_env(key, value), do: Application.put_env(:dev_ide, key, value)
end
