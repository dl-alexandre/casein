defmodule Casein.Terminals.SessionOwnerDecompositionTest do
  use Casein.TestCase, async: true

  alias Casein.Terminals.Session.Info
  alias Casein.Terminals.SessionOwner
  alias Casein.Terminals.SessionOwner.{PaneLifecycle, Recovery}

  # #934 constraint: SessionOwner stays the one GenServer per tmux session.
  # Recovery and PaneLifecycle are callback-body modules, not processes.
  # Do not add start_link/init to the helpers or change recover-vs-stop policy.

  test "process topology is unchanged: only SessionOwner is a GenServer" do
    assert function_exported?(SessionOwner, :start_link, 1)
    assert function_exported?(SessionOwner, :init, 1)
    refute function_exported?(Recovery, :start_link, 1)
    refute function_exported?(Recovery, :init, 1)
    refute function_exported?(PaneLifecycle, :start_link, 1)
    refute function_exported?(PaneLifecycle, :init, 1)
  end

  test "owner_key still names one registry process per shell session" do
    info = %Info{kind: :shell, workspace_id: "ws-decomp", sid: "sid-decomp", id: "shell_ws_sid"}
    assert SessionOwner.owner_key(info) == {:terminal_owner, :shell, "ws-decomp", "sid-decomp"}
  end

  test "Recovery keeps historic recover constants" do
    assert Recovery.backend_recover_max() == 5
    assert Recovery.backend_recover_backoff_ms() == 400
  end

  test "shell owner with subscribers recovers; agent owner stops" do
    shell = %SessionOwner{
      info: %Info{kind: :shell, id: "shell-1", sid: "s1", workspace_id: "ws"},
      subscribers: %{self() => :raw},
      attachment: nil
    }

    assert {:noreply, recovered} = Recovery.handle_term_exit(shell, :killed)
    assert is_reference(recovered.backend_recover_timer)
    _ = Recovery.cancel_backend_recover_timer(recovered)

    agent = %SessionOwner{
      info: %Info{kind: :agent, id: "agent-1", workspace_id: "ws"},
      subscribers: %{self() => :raw}
    }

    assert {:stop, :normal, _} = Recovery.handle_term_exit(agent, :killed)
  end

  test "shell owners never auto-stop after last detach; agent owners do" do
    refute PaneLifecycle.should_stop?(%SessionOwner{
             info: %Info{kind: :shell, id: "s", sid: "sid"},
             subscribers: %{}
           })

    assert PaneLifecycle.should_stop?(%SessionOwner{
             info: %Info{kind: :agent, id: "a"},
             subscribers: %{}
           })

    refute PaneLifecycle.should_stop?(%SessionOwner{
             info: %Info{kind: :agent, id: "a"},
             subscribers: %{self() => :raw}
           })
  end
end
