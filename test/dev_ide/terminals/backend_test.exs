defmodule DevIDE.Terminals.BackendTest do
  use ExUnit.Case, async: false

  alias DevIDE.Terminals.Backend
  alias DevIDE.Terminals.Backends.Tmux, as: TmuxBackend
  alias DevIDE.Terminals.Tmux

  defmodule ConfiguredBackend do
  end

  setup do
    previous_backend = Application.get_env(:dev_ide, :terminal_backend)
    previous_tmux = Application.get_env(:dev_ide, :tmux_adapter)
    Application.delete_env(:dev_ide, :terminal_backend)
    Application.delete_env(:dev_ide, :tmux_adapter)

    on_exit(fn ->
      restore(:terminal_backend, previous_backend)
      restore(:tmux_adapter, previous_tmux)
    end)
  end

  test "tmux backend implements every platform backend callback" do
    assert {:module, TmuxBackend} = Code.ensure_loaded(TmuxBackend)

    missing =
      for {name, arity} <- Backend.behaviour_info(:callbacks),
          not function_exported?(TmuxBackend, name, arity),
          do: {name, arity}

    assert missing == []
  end

  test "defaults to the tmux backend" do
    assert Backend.module() == TmuxBackend
  end

  test "keeps the historical tmux adapter override independent" do
    Application.put_env(:dev_ide, :tmux_adapter, ConfiguredBackend)
    assert Backend.module() == TmuxBackend
  end

  test "terminal backend can be configured without changing the compatibility key" do
    Application.put_env(:dev_ide, :tmux_adapter, Tmux)
    Application.put_env(:dev_ide, :terminal_backend, ConfiguredBackend)
    assert Backend.module() == ConfiguredBackend
  end

  test "tmux backend owns remote spawn construction" do
    assert {:ok, %Backend.SpawnSpec{command: command, exec_opts: []}} =
             TmuxBackend.spawn_spec({:remote, "dev@example.test", "/srv/work tree"}, "session-1")

    command = to_string(command)
    assert command =~ "ssh -tt"
    assert command =~ "dev@example.test"
    assert command =~ "tmux new-session -A -s session-1"
  end

  test "tmux backend rejects unknown location types" do
    assert {:error, {:unsupported_location, :native}} =
             TmuxBackend.spawn_spec(:native, "session-1")
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, value), do: Application.put_env(:dev_ide, key, value)
end
