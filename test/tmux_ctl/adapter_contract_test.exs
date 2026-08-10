defmodule TmuxCtl.AdapterContractTest do
  @moduledoc """
  Guards the #817 class of mystery gate reds: product code calls adapter
  functions unguarded, and a partial stub installed as `:tmux_adapter` crashes
  the whole suite when an unrelated path hits a missing export.

  Strategy (a): every module that tests install as `:tmux_adapter` must export
  the full `TmuxCtl.Adapter` behaviour. Scenario-specific overrides stay local
  and must reflect FakeState / test scenario data — never constants that keep a
  directory alive when it should stop.
  """
  use ExUnit.Case, async: false

  alias TmuxCtl.Adapter
  alias TmuxCtl.Test.{FakeAdapter, FakeState, InterventionRaceAdapter}

  @session "casein_adapter_contract_probe"

  # Modules that production tests install via Application.put_env(:casein, :tmux_adapter, …).
  # Keep this list in lockstep with `rg 'put_env\\(:casein, :tmux_adapter' test/`.
  # Intentionally excluded: unit-only stubs that are never the process-wide adapter
  # (AliveAdapter/DeadAdapter, FakeMergedTopology, PaneAliveTerminals, FakeBackend).
  @installed_adapters [
    FakeAdapter,
    Casein.Test.FakeTmuxAdapter,
    InterventionRaceAdapter,
    Casein.Terminals.SessionDirectoryEventsTest.CountingAdapter,
    Casein.FilePanesTest.CountingTmuxAdapter
  ]

  # The three functions that burned full PR-gate cycles when missing
  # (#774 session_exists?/1, #792 list_session_windows/1, #809 server_version/0).
  @historical_gaps [
    {:session_exists?, 1},
    {:list_session_windows, 1},
    {:server_version, 0}
  ]

  setup_all do
    # Nested/sibling adapters live in other test files. Compile only the adapter
    # modules (not the ExUnit cases) so this file stays runnable in isolation.
    ensure_test_adapter!(
      "test/casein/terminals/session_directory_events_test.exs",
      "defmodule Casein.Terminals.SessionDirectoryEventsTest.CountingAdapter",
      Casein.Terminals.SessionDirectoryEventsTest.CountingAdapter
    )

    ensure_test_adapter!(
      "test/casein/file_panes_test.exs",
      "defmodule Casein.FilePanesTest.CountingTmuxAdapter",
      Casein.FilePanesTest.CountingTmuxAdapter
    )

    :ok
  end

  defp ensure_test_adapter!(path, marker, mod) do
    if Code.ensure_loaded?(mod) do
      :ok
    else
      source = File.read!(path)

      case String.split(source, marker, parts: 2) do
        [_, rest] ->
          # Keep only this module — stop before the next top-level defmodule.
          body =
            case Regex.run(~r/\A.*?\nend\n(?=\n*defmodule |\z)/s, rest) do
              [only] -> only
              _ -> rest
            end

          Code.compile_string(marker <> body)
          Code.ensure_loaded!(mod)
          :ok

        _ ->
          flunk("could not find #{marker} in #{path}")
      end
    end
  end

  setup do
    previous_windows = FakeState.get(:fake_tmux_windows)
    previous_panes = FakeState.get(:fake_tmux_panes)
    previous_alive = FakeState.get(:fake_tmux_alive_sessions)
    previous_race = FakeState.get(:intervention_race_panes)
    previous_version = FakeState.get(:fake_tmux_server_version)
    previous_adapter = Application.get_env(:casein, :tmux_adapter)

    FakeState.put(:fake_tmux_windows, %{
      @session => [%{id: "@1", index: 0, name: "shell", active: true, last: false, panes: 1}]
    })

    FakeState.put(:fake_tmux_panes, %{
      @session => [
        %{
          id: "%1",
          window_id: "@1",
          index: 0,
          active: true,
          left: 0,
          top: 0,
          width: 120,
          height: 40,
          current_command: "bash",
          current_path: "/tmp"
        }
      ]
    })

    FakeState.put(:fake_tmux_alive_sessions, MapSet.new([@session]))

    FakeState.put(:intervention_race_panes, %{
      @session => [
        %{id: "%1", window_id: "@1", index: 0, active: true, role: "operator"}
      ]
    })

    FakeState.delete(:fake_tmux_server_version)

    on_exit(fn ->
      FakeState.restore(:fake_tmux_windows, previous_windows)
      FakeState.restore(:fake_tmux_panes, previous_panes)
      FakeState.restore(:fake_tmux_alive_sessions, previous_alive)
      FakeState.restore(:intervention_race_panes, previous_race)
      FakeState.restore(:fake_tmux_server_version, previous_version)

      case previous_adapter do
        nil -> Application.delete_env(:casein, :tmux_adapter)
        mod -> Application.put_env(:casein, :tmux_adapter, mod)
      end
    end)

    :ok
  end

  test "FakeAdapter and FakeTmuxAdapter export every TmuxCtl.Adapter callback" do
    callbacks = Adapter.behaviour_info(:callbacks)

    for mod <- [FakeAdapter, Casein.Test.FakeTmuxAdapter] do
      Code.ensure_loaded!(mod)

      missing =
        for {name, arity} <- callbacks,
            not function_exported?(mod, name, arity),
            do: {name, arity}

      assert missing == [], "#{inspect(mod)} missing #{inspect(missing)}"
    end
  end

  test "every :tmux_adapter-installed stub exports the full behaviour contract" do
    callbacks = Adapter.behaviour_info(:callbacks)

    for mod <- @installed_adapters do
      Code.ensure_loaded!(mod)

      missing =
        for {name, arity} <- callbacks,
            not function_exported?(mod, name, arity),
            do: {name, arity}

      assert missing == [],
             """
             #{inspect(mod)} is installed as :tmux_adapter in tests but is missing \
             #{inspect(missing)}. Complete the stub (strategy a) — do not leave \
             unguarded product calls to crash the gate. Prefer defdelegate to \
             FakeAdapter / FakeTmuxAdapter for non-scenario functions.
             """
    end
  end

  test "historical gap trio is exported and callable on every installed stub" do
    for mod <- @installed_adapters do
      Code.ensure_loaded!(mod)

      for {name, arity} <- @historical_gaps do
        assert function_exported?(mod, name, arity),
               "#{inspect(mod)} missing #{name}/#{arity} (#774/#792/#809 class)"
      end

      assert is_boolean(mod.session_exists?(@session))
      assert is_list(mod.list_session_windows(@session))
      assert match?({_, _}, mod.server_version()) or is_nil(mod.server_version())
    end
  end

  test "InterventionRaceAdapter.session_exists?/1 reflects scenario panes, not a constant" do
    assert InterventionRaceAdapter.session_exists?(@session)
    refute InterventionRaceAdapter.session_exists?("never-seeded-session")

    FakeState.put(:intervention_race_panes, %{})
    refute InterventionRaceAdapter.session_exists?(@session)
  end

  test "InterventionRaceAdapter.list_session_windows/1 derives ids from scenario panes" do
    windows = InterventionRaceAdapter.list_session_windows(@session)
    assert Enum.map(windows, & &1.id) == ["@1"]

    FakeState.put(:intervention_race_panes, %{
      @session => [
        %{id: "%1", window_id: "@7"},
        %{id: "%2", window_id: "@7"},
        %{id: "%3", window_id: "@9"}
      ]
    })

    assert InterventionRaceAdapter.list_session_windows(@session)
           |> Enum.map(& &1.id)
           |> Enum.sort() == ["@7", "@9"]
  end

  test "server_version/0 honours FakeState scenario override on partial stubs" do
    FakeState.put(:fake_tmux_server_version, {3, 6})

    assert InterventionRaceAdapter.server_version() == {3, 6}
    assert Casein.Terminals.SessionDirectoryEventsTest.CountingAdapter.server_version() == {3, 6}
    assert Casein.FilePanesTest.CountingTmuxAdapter.server_version() == {3, 6}
  end

  test "installing each stub as :tmux_adapter does not crash unguarded product paths" do
    # Mirrors the three unguarded call shapes that reded unrelated PRs:
    #   TerminalSessions → session_exists?/1
    #   SessionDirectory / AgentPromptSender → list_session_windows/1
    #   TmuxOps.tmux_version/0 → server_version/0
    for mod <- @installed_adapters do
      Application.put_env(:casein, :tmux_adapter, mod)
      adapter = Casein.Terminals.tmux_adapter()
      assert adapter == mod

      assert is_boolean(adapter.session_exists?(@session))
      assert is_list(adapter.list_session_windows(@session))

      assert match?({_, _}, Casein.Terminals.tmux_version()) or
               is_nil(Casein.Terminals.tmux_version())
    end
  end
end
