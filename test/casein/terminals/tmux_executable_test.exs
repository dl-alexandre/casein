defmodule Casein.Terminals.TmuxExecutableTest do
  use ExUnit.Case, async: false

  alias Casein.Terminals.{TmuxExecutable, TmuxRunner}

  setup do
    previous = Application.get_env(:casein, :tmux_executable)
    previous_env = System.get_env("CASEIN_TMUX_EXECUTABLE")

    on_exit(fn ->
      restore_app_env(previous)
      restore_system_env(previous_env)
    end)

    :ok
  end

  test "explicit executable is used by host argv" do
    path = System.find_executable("sh")
    Application.put_env(:casein, :tmux_executable, path)

    assert [^path | _] = TmuxRunner.host_argv(["list-sessions"])
    assert TmuxExecutable.resolve() == path
  end

  test "environment override wins over application config" do
    env_path = System.find_executable("sh")
    config_path = System.find_executable("env")
    Application.put_env(:casein, :tmux_executable, config_path)
    System.put_env("CASEIN_TMUX_EXECUTABLE", env_path)

    assert TmuxExecutable.resolve() == env_path
  end

  test "nonexistent overrides are ignored" do
    Application.put_env(:casein, :tmux_executable, "/definitely/missing/tmux")
    System.put_env("CASEIN_TMUX_EXECUTABLE", "/also/missing/tmux")

    assert TmuxExecutable.resolve() == System.find_executable("tmux")
  end

  defp restore_app_env(nil), do: Application.delete_env(:casein, :tmux_executable)
  defp restore_app_env(value), do: Application.put_env(:casein, :tmux_executable, value)

  defp restore_system_env(nil), do: System.delete_env("CASEIN_TMUX_EXECUTABLE")
  defp restore_system_env(value), do: System.put_env("CASEIN_TMUX_EXECUTABLE", value)
end
