defmodule Casein.PathsTest do
  use ExUnit.Case, async: false

  alias Casein.Paths

  setup do
    prev_home_dir = Application.get_env(:casein, :home_dir)
    prev_home = System.get_env("HOME")
    prev_profile = System.get_env("USERPROFILE")

    on_exit(fn ->
      restore_app(:home_dir, prev_home_dir)
      restore_env("HOME", prev_home)
      restore_env("USERPROFILE", prev_profile)
    end)

    :ok
  end

  test "home/0 prefers the :home_dir application override" do
    Application.put_env(:casein, :home_dir, "/tmp/casein-home-override")
    System.put_env("HOME", "/tmp/should-not-win")

    assert Paths.home() == "/tmp/casein-home-override"
    assert Paths.home!() == "/tmp/casein-home-override"
  end

  test "home/0 uses HOME then USERPROFILE without a host-specific fallback" do
    Application.delete_env(:casein, :home_dir)
    System.put_env("HOME", "/tmp/portable-home")
    System.delete_env("USERPROFILE")

    assert Paths.home() == "/tmp/portable-home"

    System.delete_env("HOME")
    System.put_env("USERPROFILE", "C:/Users/portable")

    assert Paths.home() == "C:/Users/portable"
  end

  test "home!/0 raises when no home can be resolved" do
    # Pin an empty override so present?/1 rejects it, then clear env. On hosts
    # where System.user_home/0 still resolves, home!/0 succeeds with that value
    # — which is still portable (no invented path). When it does not, home!/0
    # must raise rather than invent a host-specific fallback.
    Application.put_env(:casein, :home_dir, "")
    System.delete_env("HOME")
    System.delete_env("USERPROFILE")

    case Paths.home() do
      nil ->
        assert_raise ArgumentError, ~r/HOME or USERPROFILE is required/, fn ->
          Paths.home!()
        end

      home when is_binary(home) ->
        assert Paths.home!() == home
        assert home == System.user_home()
    end
  end

  test "product sources no longer hard-code a quoted /home/devbox fallback" do
    assert {_, 0} = System.cmd("bash", ["scripts/check-portable-defaults-guard.sh"])
  end

  defp restore_app(key, nil), do: Application.delete_env(:casein, key)
  defp restore_app(key, value), do: Application.put_env(:casein, key, value)

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
