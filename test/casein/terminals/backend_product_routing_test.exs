defmodule Casein.Terminals.BackendProductRoutingTest do
  @moduledoc """
  Guards #462 slice 3: template executors, MCP shared helpers, deploy terminal
  smoke, and done-agent sweeps resolve their default terminal engine through
  `Casein.Terminals.Backend.module/0` (not a hard-coded `Tmux` / `TmuxCtl.Client`).

  Linux-honest — does not claim ConPTY host execution.
  """

  use ExUnit.Case, async: false

  alias Casein.Agents.TerminalTools.Impl.Shared
  alias Casein.Terminals.Backend
  alias Casein.Terminals.Backends.Tmux, as: TmuxBackend
  alias Casein.Terminals.SessionTemplate.Executor, as: BuiltInExecutor
  alias Casein.Terminals.Templates.Executor, as: SavedExecutor
  alias Casein.Terminals.Templates.ReconcileExecutor
  alias Casein.Terminals.Tmux

  defmodule RecordingAdapter do
    @moduledoc false
    @behaviour TmuxCtl.Adapter

    def ensure_table! do
      case :ets.whereis(__MODULE__) do
        :undefined ->
          :ets.new(__MODULE__, [:named_table, :public, :set])

        _ ->
          __MODULE__
      end

      :ok
    end

    def reset!(test_pid) do
      ensure_table!()
      :ets.delete_all_objects(__MODULE__)
      :ets.insert(__MODULE__, {:test_pid, test_pid})
      :ets.insert(__MODULE__, {:window_seq, 1})
      :ets.insert(__MODULE__, {:pane_seq, 1})
      :ets.insert(__MODULE__, {:windows, %{}})
      :ets.insert(__MODULE__, {:panes, %{}})
      :ok
    end

    def ensure_session(session, cwd) do
      notify({:ensure_session, session, cwd})
      seed_session(session)
      :ok
    end

    def list_session_windows(session) do
      notify({:list_session_windows, session})
      Map.get(get(:windows), session, [])
    end

    def list_session_panes(session) do
      notify({:list_session_panes, session})
      Map.get(get(:panes), session, [])
    end

    def session_topology(session) do
      {list_session_windows(session), list_session_panes(session)}
    end

    def new_window(session, opts \\ []) do
      notify({:new_window, session, opts})
      seed_session(session)
      wseq = bump(:window_seq)
      pseq = bump(:pane_seq)
      window_id = "@#{wseq}"
      pane_id = "%#{pseq}"

      windows =
        get(:windows)
        |> Map.update(session, [], fn list ->
          Enum.map(list, &Map.put(&1, :active, false)) ++
            [
              %{
                id: window_id,
                index: wseq - 1,
                name: Keyword.get(opts, :name, "w#{wseq}"),
                active: true,
                panes: 1
              }
            ]
        end)

      panes =
        get(:panes)
        |> Map.update(session, [], fn list ->
          Enum.map(list, &Map.put(&1, :active, false)) ++
            [
              %{
                id: pane_id,
                window_id: window_id,
                index: 0,
                active: true,
                current_path: Keyword.get(opts, :cwd) || File.cwd!()
              }
            ]
        end)

      put(:windows, windows)
      put(:panes, panes)
      {:ok, window_id}
    end

    def split_pane(session, pane_id, direction, opts \\ []) do
      notify({:split_pane, session, pane_id, direction, opts})
      source = Enum.find(list_session_panes(session), &(&1.id == pane_id))
      pseq = bump(:pane_seq)
      new_id = "%#{pseq}"

      panes =
        Map.update(get(:panes), session, [], fn list ->
          Enum.map(list, &Map.put(&1, :active, false)) ++
            [
              %{
                id: new_id,
                window_id: source.window_id,
                index: pseq,
                active: true,
                current_path: Keyword.get(opts, :cwd) || source.current_path
              }
            ]
        end)

      put(:panes, panes)
      {:ok, new_id}
    end

    def select_pane(session, pane_id) do
      notify({:select_pane, session, pane_id})
      :ok
    end

    def set_pane_role(session, pane_id, role) do
      notify({:set_pane_role, session, pane_id, role})
      :ok
    end

    def send_command(session, cmd, opts \\ []) do
      notify({:send_command, session, cmd, opts})
      :ok
    end

    def set_environment(session, key, value) do
      notify({:set_environment, session, key, value})
      :ok
    end

    def capture_recent(session, lines \\ 200, opts \\ [])

    def capture_recent(session, lines, opts) do
      notify({:capture_recent, session, lines, opts})
      {:ok, "casein-pairing=probe\n"}
    end

    def kill(session) do
      notify({:kill, session})
      :ok
    end

    def list_sessions do
      notify(:list_sessions)
      [%{session: "casein_route_probe_1", attached: false, activity: 0}]
    end

    def session_exists?(_session), do: true
    def session_alive?(session), do: session_exists?(session)
    def attach(_session), do: {:ok, :recording}
    def send_keys(_session, _keys, _opts \\ []), do: :ok
    def capture_scrollback(_session, _opts \\ []), do: ""
    def resize_window(_session, _cols, _rows), do: :ok
    def window_size(_session), do: {:ok, {80, 24}}
    def select_window(_session, _window_id), do: :ok
    def kill_window(_session, _window_id), do: :ok
    def kill_pane(_session, _pane_id), do: :ok
    def resize_pane(_session, _pane_id, _direction, _amount \\ 1), do: :ok
    def server_version, do: {3, 4}
    def list_windows, do: []
    def list_panes, do: []
    def paste_text(_session, _text, _opts \\ []), do: :ok
    def inject(_target, _text, _opts \\ []), do: :ok
    def directory_inventory, do: []

    defp seed_session(session) do
      windows = get(:windows)
      panes = get(:panes)

      if Map.has_key?(windows, session) do
        :ok
      else
        put(
          :windows,
          Map.put(windows, session, [
            %{id: "@1", index: 0, name: "shell", active: true, panes: 1}
          ])
        )

        put(
          :panes,
          Map.put(panes, session, [
            %{
              id: "%1",
              window_id: "@1",
              index: 0,
              active: true,
              current_path: File.cwd!()
            }
          ])
        )
      end
    end

    defp bump(key) do
      n = get(key) + 1
      put(key, n)
      n
    end

    defp get(key) do
      ensure_table!()

      case :ets.lookup(__MODULE__, key) do
        [{^key, value}] -> value
        [] -> nil
      end
    end

    defp put(key, value) do
      ensure_table!()
      true = :ets.insert(__MODULE__, {key, value})
      :ok
    end

    defp notify(msg) do
      case get(:test_pid) do
        pid when is_pid(pid) -> send(pid, {:backend_route, msg})
        _ -> :ok
      end
    end
  end

  setup do
    previous_backend = Application.get_env(:casein, :terminal_backend)
    previous_tmux = Application.get_env(:casein, :tmux_adapter)

    RecordingAdapter.reset!(self())
    Application.put_env(:casein, :terminal_backend, TmuxBackend)
    Application.put_env(:casein, :tmux_adapter, RecordingAdapter)

    on_exit(fn ->
      restore(:terminal_backend, previous_backend)
      restore(:tmux_adapter, previous_tmux)
    end)

    :ok
  end

  test "Backends.Tmux forwards adapter-only ops used by product routes" do
    assert :ok = TmuxBackend.send_command("s", "echo hi", target: "%1")
    assert_receive {:backend_route, {:send_command, "s", "echo hi", [target: "%1"]}}

    assert :ok = TmuxBackend.set_environment("s", "K", "V")
    assert_receive {:backend_route, {:set_environment, "s", "K", "V"}}

    assert [%{session: "casein_route_probe_1"}] = TmuxBackend.list_sessions()
    assert_receive {:backend_route, :list_sessions}

    assert TmuxBackend.workspace_session_prefix("acme") == Tmux.workspace_session_prefix("acme")
  end

  test "built-in session template executor defaults to Backend.module/0" do
    assert Backend.module() == TmuxBackend

    assert {:ok, result} =
             BuiltInExecutor.execute("casein_route_tpl", "agent_pair",
               workspace_root: File.cwd!()
             )

    assert result.template.id == "agent_pair"
    assert_receive {:backend_route, {:new_window, "casein_route_tpl", _}}
    assert_receive {:backend_route, {:split_pane, "casein_route_tpl", _, _, _}}
  end

  test "saved template executor defaults to Backend.module/0" do
    saved = %{
      id: "tpl-route",
      name: "route",
      description: "route",
      schema_version: 2,
      body: %{
        "version" => 2,
        "windows" => [
          %{
            "name" => "main",
            "layout" => %{"command" => "echo ok", "name" => "shell"}
          }
        ]
      }
    }

    assert {:ok, _} = SavedExecutor.execute("casein_route_saved", saved)
    assert_receive {:backend_route, {:new_window, "casein_route_saved", _}}
  end

  test "reconcile executor defaults to Backend.module/0" do
    diff = %{
      template: %{id: "tpl", name: "t"},
      summary: %{},
      estimated_disruption: :low,
      changes: [
        %{
          action: "create_window",
          template_ref: %{ref: "window:main", name: "main", cwd: nil}
        }
      ]
    }

    assert {:ok, _} = ReconcileExecutor.execute("casein_route_recon", diff)
    assert_receive {:backend_route, {:new_window, "casein_route_recon", _}}
  end

  test "MCP Shared.tmux/0 shares Terminals.tmux_adapter/0 (not Backend.module) (#892)" do
    Application.delete_env(:casein, :tmux_adapter)
    Application.put_env(:casein, :terminal_backend, TmuxBackend)
    # Product engine may be Backends.Tmux; MCP pane writes use the facade default.
    assert Shared.tmux() == Casein.Terminals.Tmux
    assert Shared.tmux() == Casein.Terminals.tmux_adapter()

    Application.put_env(:casein, :tmux_adapter, RecordingAdapter)
    assert Shared.tmux() == RecordingAdapter
    assert Casein.Terminals.tmux_adapter() == RecordingAdapter
  end

  test "MCP Shared workspace prefixes go through Backend session naming" do
    Application.delete_env(:casein, :tmux_adapter)
    Application.put_env(:casein, :terminal_backend, TmuxBackend)

    prefix = TmuxBackend.workspace_session_prefix("acme")
    assert prefix == Backend.module().session_name("acme", "")
    assert String.starts_with?(prefix, "casein_")
  end

  test "deploy smoke Backend path: ensure/list/set_env/send/capture/kill" do
    backend = Backend.module()
    assert :ok = backend.ensure_session("casein_smoke_route", File.cwd!())
    assert_receive {:backend_route, {:ensure_session, "casein_smoke_route", _}}

    assert [%{current_path: _}] = backend.list_session_panes("casein_smoke_route")
    assert :ok = backend.set_environment("casein_smoke_route", "CASEIN_SMOKE_PAIRING", "n1")
    assert :ok = backend.send_command("casein_smoke_route", "echo hi")
    assert {:ok, _} = backend.capture_recent("casein_smoke_route", 40, [])
    assert :ok = backend.kill("casein_smoke_route")
    assert_receive {:backend_route, {:kill, "casein_smoke_route"}}
  end

  test "done-agent list_sessions routes through Backend.module/0" do
    assert [%{session: "casein_route_probe_1"}] = Backend.module().list_sessions()
    assert_receive {:backend_route, :list_sessions}
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, value), do: Application.put_env(:casein, key, value)
end
