defmodule Casein.Terminals.BackendContractTest do
  @moduledoc """
  Contract coverage for `Casein.Terminals.Backend` implementations.

  Linux CI proves behaviour completeness and Fake multipane topology/input.
  ConPTY tests only assert scaffold shape and fail-closed host gating — they do
  **not** claim Windows ConPTY or Job Object execution.
  """

  use ExUnit.Case, async: false

  alias Casein.Terminals.Backend
  alias Casein.Terminals.Backend.SpawnSpec
  alias Casein.Terminals.Backends.ConPTY
  alias Casein.Terminals.Backends.Fake
  alias Casein.Terminals.Backends.Tmux, as: TmuxBackend

  # Product routing tests below swap :terminal_backend / :tmux_adapter.

  @callbacks Backend.behaviour_info(:callbacks)

  @impl_modules [TmuxBackend, Fake, ConPTY]

  setup do
    Fake.reset!()
    :ok
  end

  describe "behaviour completeness" do
    test "every registered backend exports all Backend callbacks" do
      for mod <- @impl_modules do
        assert {:module, ^mod} = Code.ensure_loaded(mod)

        missing =
          for {name, arity} <- @callbacks,
              not function_exported?(mod, name, arity),
              do: {mod, name, arity}

        assert missing == [],
               "#{inspect(mod)} missing Backend callbacks: #{inspect(missing)}"
      end
    end
  end

  describe "Fake backend multipane topology" do
    @session "fake_contract_session"

    setup do
      assert :ok = Fake.ensure_session(@session, File.cwd!())
      :ok
    end

    test "creates session with operator root pane" do
      assert Fake.session_exists?(@session)
      assert Fake.session_alive?(@session)

      windows = Fake.list_session_windows(@session)
      panes = Fake.list_session_panes(@session)

      assert length(windows) == 1
      assert length(panes) == 1
      assert hd(panes).role == "operator"
      assert hd(panes).active
      assert {^windows, ^panes} = Fake.session_topology(@session)
    end

    test "new_window, split_pane, roles, select, and kill stay consistent" do
      assert {:ok, "@2"} = Fake.new_window(@session, name: "work", role: "operator")
      # new_window already created root pane %2 on @2
      assert :ok = Fake.select_window(@session, "@2")
      assert {:ok, panes_before} = ok_panes()
      root_on_2 = Enum.find(panes_before, &(&1.window_id == "@2" and &1.index == 0))
      assert root_on_2
      assert root_on_2.id == "%2"

      assert {:ok, agent_id} = Fake.split_pane(@session, root_on_2.id, "right", role: "agent")
      assert {:ok, verify_id} = Fake.split_pane(@session, root_on_2.id, "down", role: "verify")
      assert agent_id == "%3"
      assert verify_id == "%4"

      assert :ok = Fake.set_pane_role(@session, agent_id, "agent")
      assert :ok = Fake.set_pane_role(@session, verify_id, "verify")
      assert :ok = Fake.select_pane(@session, agent_id)

      {windows, panes} = Fake.session_topology(@session)
      assert length(windows) == 2
      assert Enum.count(panes, &(&1.window_id == "@2")) == 3

      roles =
        panes
        |> Enum.filter(&(&1.window_id == "@2"))
        |> Enum.map(& &1.role)
        |> Enum.sort()

      assert roles == ["agent", "operator", "verify"]
      assert Enum.find(panes, & &1.active).id == agent_id

      assert :ok = Fake.kill_pane(@session, verify_id)
      assert {:error, :invalid_pane} = Fake.select_pane(@session, verify_id)

      assert :ok = Fake.kill_window(@session, "@2")
      {windows, panes} = Fake.session_topology(@session)
      assert length(windows) == 1
      assert Enum.all?(panes, &(&1.window_id == "@1"))
    end

    test "send_keys and capture_recent target active or explicit pane" do
      assert :ok = Fake.send_keys(@session, "hello\n")
      assert {:ok, text} = Fake.capture_recent(@session, 10)
      assert text =~ "hello"

      assert {:ok, "%2"} = Fake.split_pane(@session, "%1", "right", role: "agent")
      assert :ok = Fake.send_keys(@session, "agent-only\n", target: "%2")
      assert {:ok, agent_text} = Fake.capture_recent(@session, 10, target: "%2")
      assert agent_text =~ "agent-only"

      assert {:ok, root_text} = Fake.capture_recent(@session, 10, target: "%1")
      refute root_text =~ "agent-only"
      assert Fake.capture_scrollback(@session, target: "%2") =~ "agent-only"
    end

    test "resize_window and resize_pane update geometry" do
      assert :ok = Fake.resize_window(@session, 100, 40)
      assert {:ok, {100, 40}} = Fake.window_size(@session)

      assert {:ok, "%2"} = Fake.split_pane(@session, "%1", "right")
      assert :ok = Fake.resize_pane(@session, "%2", "R", 5)

      pane = Enum.find(Fake.list_session_panes(@session), &(&1.id == "%2"))
      assert pane.width == 105
    end

    test "spawn_spec accepts local remote and native locations" do
      assert {:ok, %SpawnSpec{command: ~c"fake-backend-local"}} =
               Fake.spawn_spec({:local, "/tmp"}, @session)

      assert {:ok, %SpawnSpec{command: ~c"fake-backend-remote", exec_opts: opts}} =
               Fake.spawn_spec({:remote, "box", "/srv"}, @session)

      assert opts[:host] == "box"

      assert {:ok, %SpawnSpec{command: ~c"fake-backend-native", exec_opts: native_opts}} =
               Fake.spawn_spec({:native, "/work"}, @session)

      assert native_opts[:transport] == :conpty
      assert {:error, {:unsupported_location, :other}} = Fake.spawn_spec(:other, @session)
    end

    test "kill removes the session" do
      assert :ok = Fake.kill(@session)
      refute Fake.session_exists?(@session)
      refute Fake.session_alive?(@session)
      assert Fake.list_session_windows(@session) == []
    end

    test "rejects last pane and last window" do
      assert {:error, :last_pane} = Fake.kill_pane(@session, "%1")
      assert {:error, :last_window} = Fake.kill_window(@session, "@1")
    end

    test "Backend.module/0 can select Fake without touching tmux_adapter" do
      previous = Application.get_env(:casein, :terminal_backend)
      previous_tmux = Application.get_env(:casein, :tmux_adapter)

      on_exit(fn ->
        restore(:terminal_backend, previous)
        restore(:tmux_adapter, previous_tmux)
      end)

      Application.put_env(:casein, :tmux_adapter, :not_a_backend)
      Application.put_env(:casein, :terminal_backend, Fake)
      assert Backend.module() == Fake
    end

    test "TmuxOps session/pane helpers route through Backend.module/0" do
      previous = Application.get_env(:casein, :terminal_backend)
      previous_tmux = Application.get_env(:casein, :tmux_adapter)

      on_exit(fn ->
        restore(:terminal_backend, previous)
        restore(:tmux_adapter, previous_tmux)
      end)

      Application.put_env(:casein, :terminal_backend, Fake)
      Application.put_env(:casein, :tmux_adapter, :not_a_backend)

      assert Casein.Terminals.backend() == Fake
      name = Casein.Terminals.tmux_session_name("ws-ops", "sid-1")
      assert name == Fake.session_name("ws-ops", "sid-1")

      assert String.starts_with?(
               Casein.Terminals.tmux_workspace_session_prefix("ws-ops"),
               "fake_"
             )

      assert :ok = Fake.ensure_session(name, File.cwd!())
      assert {:ok, agent} = Casein.Terminals.split_tmux_pane(name, "%1", "right", role: "agent")
      assert is_binary(agent)
      assert :ok = Casein.Terminals.select_tmux_pane(name, agent)
      assert :ok = Casein.Terminals.resize_tmux_pane(name, agent, "R", 2)
      assert :ok = Casein.Terminals.kill_tmux_pane(name, agent)
      assert :ok = Casein.Terminals.kill_tmux_session_exact(name)
      refute Fake.session_exists?(name)
    end

    test "SessionDirectory.Compose names default shells via Backend" do
      previous = Application.get_env(:casein, :terminal_backend)

      on_exit(fn -> restore(:terminal_backend, previous) end)

      Application.put_env(:casein, :terminal_backend, Fake)

      [tab] =
        Casein.Terminals.SessionDirectory.Compose.with_default_shell(
          [],
          "u-alice",
          "ws-id",
          "compose-ws"
        )

      assert tab.tmux_session == Fake.session_name("compose-ws", "u-alice")
    end

    test "Panes.Terminal.terminate/1 kills through Backend" do
      previous = Application.get_env(:casein, :terminal_backend)
      previous_tmux = Application.get_env(:casein, :tmux_adapter)

      on_exit(fn ->
        restore(:terminal_backend, previous)
        restore(:tmux_adapter, previous_tmux)
      end)

      Application.put_env(:casein, :terminal_backend, Fake)
      Application.put_env(:casein, :tmux_adapter, :not_a_backend)

      assert :ok = Fake.ensure_session(@session, File.cwd!())
      assert {:ok, pane} = Fake.split_pane(@session, "%1", "right", [])
      assert :ok = Casein.Panes.Terminal.terminate({@session, pane})
      panes = Fake.list_session_panes(@session)
      refute Enum.any?(panes, &(&1.id == pane))
    end
  end

  describe "Tmux backend adapter forwarding (Linux-honest)" do
    defmodule CountingAdapter do
      @moduledoc false
      def configure(pid) when is_pid(pid), do: :persistent_term.put({__MODULE__, :pid}, pid)

      defp notify(msg) do
        case :persistent_term.get({__MODULE__, :pid}, nil) do
          pid when is_pid(pid) -> send(pid, msg)
          _ -> :ok
        end
      end

      def session_exists?(session) do
        notify({:counting_exists, session})
        true
      end

      def session_exists?(session, opts) do
        notify({:counting_exists_opts, session, opts})
        true
      end

      def kill(session) do
        notify({:counting_kill, session})
        :ok
      end

      def resize_window(session, cols, rows) do
        notify({:counting_resize, session, cols, rows})
        :ok
      end

      def window_size(session) do
        notify({:counting_window_size, session})
        {:ok, {80, 24}}
      end

      def kill_pane(session, pane_id) do
        notify({:counting_kill_pane, session, pane_id})
        :ok
      end
    end

    setup do
      previous = Application.get_env(:casein, :tmux_adapter)
      previous_backend = Application.get_env(:casein, :terminal_backend)
      Application.delete_env(:casein, :terminal_backend)
      Application.put_env(:casein, :tmux_adapter, CountingAdapter)
      CountingAdapter.configure(self())

      on_exit(fn ->
        restore(:tmux_adapter, previous)
        restore(:terminal_backend, previous_backend)
      end)

      :ok
    end

    test "Backends.Tmux forwards runtime ops through :tmux_adapter" do
      assert TmuxBackend.session_exists?("s1")
      assert_received {:counting_exists, "s1"}

      assert TmuxBackend.session_exists?("s2", cwd: "/tmp")
      assert_received {:counting_exists_opts, "s2", [cwd: "/tmp"]}

      assert :ok = TmuxBackend.kill("s3")
      assert_received {:counting_kill, "s3"}

      assert :ok = TmuxBackend.resize_window("s4", 100, 30)
      assert_received {:counting_resize, "s4", 100, 30}

      assert {:ok, {80, 24}} = TmuxBackend.window_size("s5")
      assert_received {:counting_window_size, "s5"}

      assert :ok = TmuxBackend.kill_pane("s6", "%9")
      assert_received {:counting_kill_pane, "s6", "%9"}
    end

    test "session_name stays on TmuxPolicy even when adapter is swapped" do
      # Naming is not part of TmuxCtl.Adapter; product still gets casein_ prefixes.
      name = TmuxBackend.session_name("my-ws", "u-1")
      assert String.starts_with?(name, "casein_")
      assert String.contains?(name, "my-ws")
    end
  end

  describe "product modules avoid hardcoding Casein.Terminals.Tmux for Backend ops" do
    @routed_sources [
      "lib/casein/terminals/session_owner.ex",
      "lib/casein/terminals/session_directory/compose.ex",
      "lib/casein/runtimes.ex",
      "lib/casein/runtimes/worktree_alarm.ex",
      "lib/casein/terminals/tmux_janitor.ex",
      "lib/casein/panes/terminal.ex"
    ]

    test "converted modules do not call Tmux.session_name/2 or Tmux.kill/1 directly" do
      root = File.cwd!()

      for rel <- @routed_sources do
        src = File.read!(Path.join(root, rel))
        refute src =~ ~r/\bTmux\.session_name\b/, "#{rel} still calls Tmux.session_name"
        refute src =~ ~r/\bTmux\.kill\b/, "#{rel} still calls Tmux.kill"
        refute src =~ ~r/\bTmux\.session_exists\?/, "#{rel} still calls Tmux.session_exists?"
        assert src =~ "Backend", "#{rel} should reference Backend"
      end
    end
  end

  describe "ConPTY scaffold (Linux-honest)" do
    test "names sessions stably from workspace and sid" do
      a = ConPTY.session_name("ws", "main")
      b = ConPTY.session_name("ws", "main")
      c = ConPTY.session_name("ws", "other")
      assert a == b
      assert a != c
      assert String.starts_with?(a, "conpty_")
    end

    test "native spawn_spec describes ConPTY/Job Object intent without host execution" do
      assert {:ok, %SpawnSpec{command: command, exec_opts: opts}} =
               ConPTY.spawn_spec({:native, "/data/work"}, "conpty_sess")

      assert command == [
               ~c"casein-conpty",
               ~c"--session",
               ~c"conpty_sess",
               ~c"--shell",
               ~c"powershell.exe"
             ]

      assert opts[:transport] == :conpty
      assert opts[:job_object] == :kill_on_close
      assert opts[:create_suspended] == true
      assert opts[:cd] == ~c"/data/work"
    end

    test "rejects remote locations that belong to tmux" do
      assert {:error, {:unsupported_location, {:remote, "h", "/p"}}} =
               ConPTY.spawn_spec({:remote, "h", "/p"}, "s")
    end

    test "session ops fail closed on non-Windows hosts" do
      # This suite runs on Linux agents. Do not claim Windows coverage here.
      refute ConPTY.windows_host?()
      refute ConPTY.session_exists?("missing")
      refute ConPTY.session_alive?("missing")
      assert ConPTY.list_session_windows("missing") == []
      assert ConPTY.list_session_panes("missing") == []
      assert ConPTY.session_topology("missing") == {[], []}

      assert {:error, :windows_host_required} = ConPTY.ensure_session("s", File.cwd!())
      assert {:error, :windows_host_required} = ConPTY.attach("s")
      assert {:error, :windows_host_required} = ConPTY.kill("s")
      assert {:error, :windows_host_required} = ConPTY.send_keys("s", "x")
      assert {:error, :windows_host_required} = ConPTY.capture_recent("s", 5)
      assert ConPTY.capture_scrollback("s") == ""
      assert {:error, :windows_host_required} = ConPTY.resize_window("s", 80, 24)
      assert {:error, :windows_host_required} = ConPTY.window_size("s")
      assert {:error, :windows_host_required} = ConPTY.new_window("s", [])
      assert {:error, :windows_host_required} = ConPTY.select_window("s", "@1")
      assert {:error, :windows_host_required} = ConPTY.kill_window("s", "@1")
      assert {:error, :windows_host_required} = ConPTY.split_pane("s", "%1", "right")
      assert {:error, :windows_host_required} = ConPTY.select_pane("s", "%1")
      assert {:error, :windows_host_required} = ConPTY.kill_pane("s", "%1")
      assert {:error, :windows_host_required} = ConPTY.resize_pane("s", "%1", "R", 1)
      assert {:error, :windows_host_required} = ConPTY.set_pane_role("s", "%1", "agent")

      assert {:error, :windows_host_required} = ConPTY.spawn_spec({:local, "/tmp"}, "s")
    end

    test "windows_host?/1 is true only for win32 tuples" do
      assert ConPTY.windows_host?({:win32, :nt})
      refute ConPTY.windows_host?({:unix, :linux})
      refute ConPTY.windows_host?({:unix, :darwin})
    end
  end

  defp ok_panes do
    {:ok, Fake.list_session_panes(@session)}
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, value), do: Application.put_env(:casein, key, value)
end
