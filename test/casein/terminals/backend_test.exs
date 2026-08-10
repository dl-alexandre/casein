defmodule Casein.Terminals.BackendTest do
  use ExUnit.Case, async: false

  alias Casein.Terminals.Backend
  alias Casein.Terminals.Backends.Tmux, as: TmuxBackend
  alias Casein.Terminals.Tmux

  defmodule ConfiguredBackend do
  end

  setup do
    previous_backend = Application.get_env(:casein, :terminal_backend)
    previous_tmux = Application.get_env(:casein, :tmux_adapter)
    Application.delete_env(:casein, :terminal_backend)
    Application.delete_env(:casein, :tmux_adapter)

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

  test "Fake and ConPTY peers also implement every Backend callback" do
    for mod <- [Casein.Terminals.Backends.Fake, Casein.Terminals.Backends.ConPTY] do
      assert {:module, ^mod} = Code.ensure_loaded(mod)

      missing =
        for {name, arity} <- Backend.behaviour_info(:callbacks),
            not function_exported?(mod, name, arity),
            do: {mod, name, arity}

      assert missing == []
    end
  end

  test "defaults to the tmux backend" do
    assert Backend.module() == TmuxBackend
  end

  test "keeps the historical tmux adapter override independent" do
    Application.put_env(:casein, :tmux_adapter, ConfiguredBackend)
    assert Backend.module() == TmuxBackend
  end

  test "terminal backend can be configured without changing the compatibility key" do
    Application.put_env(:casein, :tmux_adapter, Tmux)
    Application.put_env(:casein, :terminal_backend, ConfiguredBackend)
    assert Backend.module() == ConfiguredBackend
  end

  test "tmux backend owns remote spawn construction" do
    assert {:ok, %Backend.SpawnSpec{command: command, exec_opts: []}} =
             TmuxBackend.spawn_spec({:remote, "dev@example.test", "/srv/work tree"}, "session-1")

    command = to_string(command)
    assert command =~ "ssh -tt"
    assert command =~ "dev@example.test"
    # Always isolated on the labeled server (issue #556); label comes from env config.
    assert command =~ ~r/tmux(?: -L \S+)?(?: -f \S+)? new-session -A -s session-1/
  end

  test "remote spawn_spec uses the configured labeled tmux server (-L)" do
    previous = Application.get_env(:casein, :tmux_server_label)
    previous_conf = Application.get_env(:casein, :tmux_remote_config_file)
    previous_env = System.get_env("CASEIN_TMUX_REMOTE_CONFIG")
    Application.put_env(:casein, :tmux_server_label, "casein")
    Application.delete_env(:casein, :tmux_remote_config_file)
    System.delete_env("CASEIN_TMUX_REMOTE_CONFIG")

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:casein, :tmux_server_label)
        value -> Application.put_env(:casein, :tmux_server_label, value)
      end

      case previous_conf do
        nil -> Application.delete_env(:casein, :tmux_remote_config_file)
        value -> Application.put_env(:casein, :tmux_remote_config_file, value)
      end

      case previous_env do
        nil -> System.delete_env("CASEIN_TMUX_REMOTE_CONFIG")
        value -> System.put_env("CASEIN_TMUX_REMOTE_CONFIG", value)
      end
    end)

    assert {:ok, %Backend.SpawnSpec{command: command}} =
             TmuxBackend.spawn_spec({:remote, "box", "/srv/app"}, "casein_ws_main")

    command = to_string(command)

    assert command =~
             "tmux -L casein -f ~/.casein/tmux/casein.conf new-session -A -s casein_ws_main"

    refute command =~ ~r/exec tmux new-session/
  end

  test "remote spawn_spec honors :tmux_remote_config_file override" do
    previous = Application.get_env(:casein, :tmux_server_label)
    previous_conf = Application.get_env(:casein, :tmux_remote_config_file)
    previous_env = System.get_env("CASEIN_TMUX_REMOTE_CONFIG")
    Application.put_env(:casein, :tmux_server_label, "casein_dev")
    Application.put_env(:casein, :tmux_remote_config_file, "/opt/casein/tmux.conf")
    System.delete_env("CASEIN_TMUX_REMOTE_CONFIG")

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:casein, :tmux_server_label)
        value -> Application.put_env(:casein, :tmux_server_label, value)
      end

      case previous_conf do
        nil -> Application.delete_env(:casein, :tmux_remote_config_file)
        value -> Application.put_env(:casein, :tmux_remote_config_file, value)
      end

      case previous_env do
        nil -> System.delete_env("CASEIN_TMUX_REMOTE_CONFIG")
        value -> System.put_env("CASEIN_TMUX_REMOTE_CONFIG", value)
      end
    end)

    assert {:ok, %Backend.SpawnSpec{command: command}} =
             TmuxBackend.spawn_spec({:remote, "box", "/srv/app"}, "sess")

    command = to_string(command)
    assert command =~ "tmux -L casein_dev -f /opt/casein/tmux.conf new-session -A -s sess"
  end

  test "tmux backend rejects unknown location types" do
    assert {:error, {:unsupported_location, :native}} =
             TmuxBackend.spawn_spec(:native, "session-1")
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, value), do: Application.put_env(:casein, key, value)
end
