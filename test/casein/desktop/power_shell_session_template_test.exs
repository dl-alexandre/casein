defmodule Casein.Desktop.PowerShellSessionTemplateTest do
  use ExUnit.Case, async: true

  alias Casein.Desktop.PowerShellSession

  defmodule FakeTransport do
    @behaviour Casein.Desktop.PowerShellPane.Transport

    @impl true
    def start(_cwd, _env, _cols, _rows, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      {:ok, term} = Agent.start_link(fn -> {:owner, test_pid, :terminal} end)
      {:ok, pty} = Agent.start_link(fn -> {:owner, test_pid, :pty} end)
      send(test_pid, {:transport_started, term, pty})
      {:ok, term, pty}
    end

    @impl true
    def write(pty, data) do
      send(test_pid(pty), {:transport_write, pty, IO.iodata_to_binary(data)})
      :ok
    end

    @impl true
    def resize(term, pty, cols, rows) do
      send(test_pid(term), {:transport_resize, term, pty, cols, rows})
      :ok
    end

    @impl true
    def terminal_write(term, data) do
      send(test_pid(term), {:terminal_write, term, IO.iodata_to_binary(data)})
      :ok
    end

    @impl true
    def close(term, pty) do
      receiver = test_pid(term)
      send(receiver, {:transport_closed, term, pty})
      if Process.alive?(pty), do: Agent.stop(pty)
      if Process.alive?(term), do: Agent.stop(term)
      :ok
    end

    defp test_pid(agent) do
      Agent.get(agent, fn
        {:owner, pid, _kind} -> pid
        _state -> raise "fake transport owner is unavailable"
      end)
    end
  end

  test "applies agent_pair onto multipane topology with roles and startup commands" do
    session = start_session()
    assert_receive {:transport_started, _term0, pty0}

    assert {:ok, result} =
             GenServer.call(
               session,
               {:apply_template, "agent_pair", [workspace_root: File.cwd!()]}
             )

    assert_receive {:transport_started, _term_agent, pty_agent}
    assert_receive {:transport_started, _term_verify, pty_verify}

    assert result.template.id == "agent_pair"
    assert result.step_count >= 4
    assert length(result.topology.windows) == 1
    assert length(result.topology.panes) == 3

    roles = result.topology.panes |> Enum.map(& &1.role) |> Enum.sort()
    assert roles == ["agent", "operator", "verify"]

    assert Enum.count(result.topology.panes, & &1.active?) == 1
    assert Enum.find(result.topology.panes, & &1.active?).role == "operator"

    assert hd(result.topology.windows).name == "work"

    assert_receive {:transport_write, ^pty_agent, agent_cmd}
    assert agent_cmd =~ "Casein agent pane"
    assert String.ends_with?(agent_cmd, "\r")

    assert_receive {:transport_write, ^pty_verify, verify_cmd}
    assert verify_cmd =~ "git status"
    assert String.ends_with?(verify_cmd, "\r")

    refute_received {:transport_write, ^pty0, _}

    assert Enum.any?(result.executed_steps, fn step ->
             step.action == "new_window" and get_in(step, [:result, :adopted_default?]) == true
           end)
  end

  test "second template apply creates a fresh window instead of re-adopting" do
    session = start_session()
    assert_receive {:transport_started, _term0, _pty0}

    assert {:ok, first} =
             GenServer.call(
               session,
               {:apply_template, "agent_pair", [workspace_root: File.cwd!()]}
             )

    assert_receive {:transport_started, _, _}
    assert_receive {:transport_started, _, _}
    assert length(first.topology.windows) == 1
    assert length(first.topology.panes) == 3

    assert {:ok, second} =
             GenServer.call(
               session,
               {:apply_template, "agent_pair", [workspace_root: File.cwd!()]}
             )

    assert_receive {:transport_started, _, _}
    assert_receive {:transport_started, _, _}
    assert_receive {:transport_started, _, _}

    assert length(second.topology.windows) == 2
    assert length(second.topology.panes) == 6

    assert Enum.any?(second.executed_steps, fn step ->
             step.action == "new_window" and get_in(step, [:result, :adopted_default?]) == false
           end)
  end

  test "unknown template id fails closed without mutating topology" do
    session = start_session()
    assert_receive {:transport_started, _term0, _pty0}

    before = GenServer.call(session, :topology)

    assert {:error, :template_not_found} =
             GenServer.call(session, {:apply_template, "no_such_template", []})

    assert GenServer.call(session, :topology) == before
  end

  defp start_session do
    name = :"native-template-#{System.unique_integer([:positive])}"

    start_supervised!(
      {PowerShellSession,
       cwd: File.cwd!(),
       workspace: %{id: "template-#{System.unique_integer([:positive])}"},
       name: name,
       transport: FakeTransport,
       transport_opts: [test_pid: self()]}
    )
  end
end
