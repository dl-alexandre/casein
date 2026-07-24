# Remote-workspace coverage for FilePanes. The local-only suite missed the
# #313 -> #319 regression: the broadcast-cascade fix made `workspace_loc/1`
# universally state-only, which silently dropped `{:remote, host, path}` loc
# resolution for the CALLER-side file read/write paths (save_tab/reload_tab).
# These tests pin the split: caller-side stays remote-capable; the in-server
# broadcast payload stays state-only (never a Manager HTTP resolve).

defmodule Casein.FilePanesRemoteTest.RemoteSource do
  @moduledoc false
  # A workspace source whose workspaces resolve to a REMOTE host loc, without
  # any Manager HTTP or State record — so `workspace_loc/1` (full resolve) sees
  # `{:remote, _, _}` while `workspace_loc_state_only/1` (State-only) sees
  # nothing and degrades. Only the callbacks FilePanes exercises are meaningful;
  # the rest are inert stubs (optional callbacks omitted).
  @behaviour Casein.WorkspaceSource

  alias Casein.Workspace

  @host "boxhost"
  @root "/remote/ws"

  def host, do: @host
  def root, do: @root

  @impl true
  def get(id, _auth \\ nil),
    do: {:ok, %Workspace{id: id, name: id, path: @root, status: :running}}

  @impl true
  def safe_host_loc(%{path: path}) when is_binary(path) and path != "",
    do: {:ok, {:remote, @host, path}}

  def safe_host_loc(_), do: {:error, :missing_path}

  @impl true
  def safe_host_path(%{path: path}) when is_binary(path) and path != "", do: {:ok, path}
  def safe_host_path(_), do: {:error, :missing_path}

  @impl true
  def list(_opts \\ [], _auth \\ nil), do: {:ok, []}
  @impl true
  def create(_params, _auth \\ nil), do: {:error, :not_supported}
  @impl true
  def start(_id, _auth \\ nil), do: {:ok, :noop}
  @impl true
  def stop(_id, _auth \\ nil), do: {:ok, :noop}
  @impl true
  def delete(_id, _opts \\ [], _auth \\ nil), do: {:ok, :noop}
  @impl true
  def stream_logs(_id, _service, _pid), do: {:error, :not_supported}
end

defmodule Casein.FilePanesRemoteTest do
  use Casein.DataCase, async: false

  alias Casein.FilePanes
  alias Casein.FilePanesRemoteTest.RemoteSource
  alias Casein.Panes.Events, as: PaneEvents
  alias Casein.Test.FakeSshRunner
  alias Casein.Workspace
  alias TmuxCtl.Test.FakeAdapter
  alias TmuxCtl.Test.FakeState

  @session "devide_rw_u-dev"
  @anchor "%r1"

  setup do
    prev_tmux = Application.get_env(:casein, :tmux_adapter)
    prev_src = Application.get_env(:casein, :workspace_source)
    prev_ssh = Application.get_env(:casein, :ssh_runner)
    Application.put_env(:casein, :tmux_adapter, FakeAdapter)
    Application.put_env(:casein, :workspace_source, RemoteSource)
    Application.put_env(:casein, :ssh_runner, FakeSshRunner)
    FilePanes.clear()

    FakeState.put(:fake_tmux_windows, %{
      @session => [%{id: "@1", index: 0, name: "bash", active: true, panes: 1, activity: 0}]
    })

    FakeState.put(:fake_tmux_panes, %{
      @session => [
        %{
          id: @anchor,
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

    on_exit(fn ->
      FilePanes.clear()
      FakeState.delete(:fake_tmux_windows)
      FakeState.delete(:fake_tmux_panes)
      restore(:tmux_adapter, prev_tmux)
      restore(:workspace_source, prev_src)
      restore(:ssh_runner, prev_ssh)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, val), do: Application.put_env(:casein, key, val)

  defp remote_ws, do: %Workspace{id: "ws-remote", name: "remote", path: RemoteSource.root()}

  defp open_remote_pane!(rel) do
    # The remote `dd` read backs both the open preflight and reload.
    FakeSshRunner.set(fn host, _argv ->
      send(self(), {:ssh_called, host})
      {:ok, "REMOTE BODY\n"}
    end)

    assert {:ok, %{pane_id: pane_id}} =
             FilePanes.open_file_in_pane(remote_ws(), rel,
               tmux_session: @session,
               anchor_pane_id: @anchor
             )

    pane_id
  end

  test "reload_tab on a remote workspace reads over ssh (caller-side loc stays remote-capable)" do
    pane_id = open_remote_pane!("lib/foo.ex")

    # reload_tab -> workspace_loc/1 must resolve {:remote, host, path} and read
    # via FileAccess's remote (ssh) clause. Under the #313 state-only bug this
    # degraded to :workspace_not_found (the remote workspace has no State record)
    # or a wrong local read — so this assertion is the regression tripwire.
    assert {:ok, %{content: "REMOTE BODY\n"}} = FilePanes.reload_tab(pane_id, "lib/foo.ex")
    assert_received {:ssh_called, "boxhost"}
  end

  test "the in-server broadcast payload stays state-only for a remote workspace" do
    # active_payload uses workspace_loc_state_only/1 — it must NOT resolve the
    # remote loc (that would be a Manager HTTP call inside the singleton, the
    # cascade root). With no State record it degrades: the broadcast omits active
    # content with a workspace_not_found error rather than blocking on ssh/HTTP.
    PaneEvents.subscribe("ws-remote")
    pane_id = open_remote_pane!("lib/bar.ex")

    assert_receive {:pane_event, %{type: :file, pane_id: ^pane_id, payload: payload}}, 2_000
    assert %{active: %{error: :workspace_not_found}} = payload
  end

  test "save_tab on a remote workspace writes over ssh (caller-side loc stays remote-capable)" do
    # save_tab -> workspace_loc/1 must resolve {:remote, host, path} so
    # FileAccess.write_text can optimistic-concurrency-read then write via ssh.
    # Under the #313 state-only bug this degraded to :workspace_not_found.
    pane_id = open_remote_pane!("lib/foo.ex")

    assert {:ok, %{version: version}} = FilePanes.reload_tab(pane_id, "lib/foo.ex")

    test = self()

    FakeSshRunner.set_stdin(fn host, _argv, stdin ->
      send(test, {:ssh_stdin, host, stdin})
      :ok
    end)

    assert {:ok, %{size: size}} = FilePanes.save_tab(pane_id, "lib/foo.ex", "UPDATED\n", version)
    assert size == byte_size("UPDATED\n")
    assert_received {:ssh_stdin, "boxhost", "UPDATED\n"}
  end
end
