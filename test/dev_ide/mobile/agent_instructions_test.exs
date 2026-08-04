defmodule DevIDE.Mobile.AgentInstructionsTest do
  # DataCase, not TestCase: the idempotency tests read and write
  # `mobile_action_outcomes`, so they need the Ecto sandbox.
  use DevIde.DataCase, async: false

  alias DevIDE.Agents.Activity
  alias DevIDE.Audit
  alias DevIDE.Labels
  alias DevIDE.Mobile.AgentInstructions
  alias TmuxCtl.Test.FakeState

  @workspace_id "ws-mobile-instructions"
  @session "devide_alpha_agent"

  setup do
    prev = %{
      test_pid: FakeState.get(:fake_tmux_test_pid),
      adapter: Application.get_env(:dev_ide, :tmux_adapter),
      windows: FakeState.get(:fake_tmux_windows),
      panes: FakeState.get(:fake_tmux_panes),
      session_meta: FakeState.get(:fake_tmux_session_meta)
    }

    FakeState.put(:fake_tmux_test_pid, self())
    FakeState.put(:fake_tmux_windows, %{})
    FakeState.put(:fake_tmux_panes, %{})
    FakeState.put(:fake_tmux_session_meta, %{})
    Audit.clear()
    Activity.clear()
    Labels.clear()
    Application.put_env(:dev_ide, :tmux_adapter, TmuxCtl.Test.FakeAdapter)

    on_exit(fn ->
      Audit.clear()
      Activity.clear()
      Labels.clear()
      restore(:fake_tmux_test_pid, prev.test_pid)
      restore(:fake_tmux_windows, prev.windows)
      restore(:fake_tmux_panes, prev.panes)
      restore(:fake_tmux_session_meta, prev.session_meta)

      case prev.adapter do
        nil -> Application.delete_env(:dev_ide, :tmux_adapter)
        adapter -> Application.put_env(:dev_ide, :tmux_adapter, adapter)
      end
    end)

    :ok
  end

  describe "targets/2" do
    test "lists the role-marked agent pane of each workspace session" do
      seed_agent_pane()

      assert [%{tmux_session: @session, pane_id: "%2"}] =
               AgentInstructions.targets(@workspace_id,
                 tmux_sessions: [@session],
                 workspace_name: "alpha"
               )
    end

    test "is empty when no session carries an agent pane" do
      seed_agent_pane(pane_role: "shell")

      assert AgentInstructions.targets(@workspace_id,
               tmux_sessions: [@session],
               workspace_name: "alpha"
             ) == []
    end
  end

  describe "send/3" do
    test "pastes into the resolved agent pane and reports the send" do
      seed_agent_pane()

      assert {:ok, summary} =
               AgentInstructions.send(
                 context(),
                 %{"workspace_id" => @workspace_id, "text" => "run the failing test again"},
                 tmux_sessions: [@session],
                 workspace_name: "alpha"
               )

      assert summary.tmux_session == @session
      assert summary.pane_id == "%2"
      assert summary.chunks_sent == 1
      assert summary.submitted
      assert_receive {:fake_tmux_paste_text, @session, "%2", "run the failing test again", _opts}
    end

    test "submit: false pastes without pressing enter" do
      seed_agent_pane()

      assert {:ok, summary} =
               AgentInstructions.send(
                 context(),
                 %{
                   "workspace_id" => @workspace_id,
                   "text" => "look at this",
                   "submit" => false
                 },
                 tmux_sessions: [@session],
                 workspace_name: "alpha"
               )

      refute summary.submitted
    end

    test "stamps mobile provenance on the audit event" do
      seed_agent_pane()

      assert {:ok, _summary} =
               AgentInstructions.send(
                 context(),
                 %{"workspace_id" => @workspace_id, "text" => "ship it"},
                 tmux_sessions: [@session],
                 workspace_name: "alpha"
               )

      assert event =
               Audit.list(workspace_id: @workspace_id)
               |> Enum.find(&String.starts_with?(&1.action, "terminal.agent_prompt_"))

      assert event.actor_id == "user-1"
      assert event.metadata["origin"] == "mobile"
      assert event.metadata["platform"] == "ios"
      assert event.metadata["device_link_id"] == "link-1"
    end

    test "rejects empty and oversized instructions before touching tmux" do
      seed_agent_pane()

      assert {:error, :empty_instruction} =
               AgentInstructions.send(
                 context(),
                 %{"workspace_id" => @workspace_id, "text" => "   "},
                 tmux_sessions: [@session],
                 workspace_name: "alpha"
               )

      too_long = String.duplicate("x", AgentInstructions.max_bytes() + 1)

      assert {:error, :instruction_too_long} =
               AgentInstructions.send(
                 context(),
                 %{"workspace_id" => @workspace_id, "text" => too_long},
                 tmux_sessions: [@session],
                 workspace_name: "alpha"
               )

      refute_receive {:fake_tmux_paste_text, _session, _pane, _text, _opts}
    end

    test "a retried request_id replays instead of pasting twice" do
      seed_agent_pane()

      params = %{
        "workspace_id" => @workspace_id,
        "text" => "fix the failing test",
        "request_id" => "outbox-1"
      }

      assert {:ok, first} =
               AgentInstructions.send(context(), params,
                 tmux_sessions: [@session],
                 workspace_name: "alpha"
               )

      refute first.replayed
      assert_receive {:fake_tmux_paste_text, @session, "%2", "fix the failing test", _opts}

      assert {:ok, second} =
               AgentInstructions.send(context(), params,
                 tmux_sessions: [@session],
                 workspace_name: "alpha"
               )

      assert second.replayed
      assert second.pane_id == first.pane_id
      refute_receive {:fake_tmux_paste_text, _session, _pane, "fix the failing test", _opts}
    end

    test "a different request_id sends again" do
      seed_agent_pane()

      for request_id <- ["outbox-1", "outbox-2"] do
        assert {:ok, summary} =
                 AgentInstructions.send(
                   context(),
                   %{
                     "workspace_id" => @workspace_id,
                     "text" => "again",
                     "request_id" => request_id
                   },
                   tmux_sessions: [@session],
                   workspace_name: "alpha"
                 )

        refute summary.replayed
      end
    end

    test "a client-supplied session outside the workspace is refused" do
      seed_agent_pane()

      assert {:error, :unknown_target} =
               AgentInstructions.send(
                 context(),
                 %{
                   "workspace_id" => @workspace_id,
                   "text" => "hello",
                   "tmux_session" => "someone_elses_session"
                 },
                 tmux_sessions: [@session],
                 workspace_name: "alpha"
               )
    end

    test "reports when the workspace has no agent pane" do
      seed_agent_pane(pane_role: "shell")

      assert {:error, :agent_pane_not_found} =
               AgentInstructions.send(
                 context(),
                 %{"workspace_id" => @workspace_id, "text" => "hello"},
                 tmux_sessions: [@session],
                 workspace_name: "alpha"
               )
    end
  end

  defp context do
    %{user_id: "user-1", device_link_id: "link-1", platform: "ios"}
  end

  defp seed_agent_pane(opts \\ []) do
    pane_role = Keyword.get(opts, :pane_role, "agent")

    FakeState.put(:fake_tmux_windows, %{
      @session => [
        %{
          id: "@1",
          index: 0,
          name: "work",
          active: true,
          panes: 1,
          activity: 0,
          current_command: "bash"
        }
      ]
    })

    FakeState.put(:fake_tmux_panes, %{
      @session => [
        %{
          id: "%2",
          window_id: "@1",
          index: 0,
          active: true,
          current_command: "bash",
          current_path: "/workspace",
          role: pane_role
        }
      ]
    })
  end

  defp restore(key, nil), do: FakeState.delete(key)
  defp restore(key, value), do: FakeState.put(key, value)
end
