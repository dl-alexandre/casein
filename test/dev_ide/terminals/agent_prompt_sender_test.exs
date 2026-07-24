defmodule Casein.Terminals.AgentPromptSenderTest do
  use Casein.TestCase, async: false

  alias Casein.Terminals
  alias Casein.Terminals.AgentPromptSender
  alias Casein.Agents.Activity
  alias Casein.Audit
  alias Casein.Labels
  alias TmuxCtl.Test.FakeState

  defmodule FailingTmux do
    def paste_text(session, text, opts) do
      send(Process.whereis(__MODULE__), {:failing_tmux_paste_text, session, text, opts})

      if String.trim_trailing(text, "\n") == "fail" do
        {:error, :paste_failed}
      else
        :ok
      end
    end
  end

  setup do
    prev_test_pid = FakeState.get(:fake_tmux_test_pid)
    prev_tmux_adapter = Application.get_env(:dev_ide, :tmux_adapter)
    prev_windows = FakeState.get(:fake_tmux_windows)
    prev_panes = FakeState.get(:fake_tmux_panes)
    prev_session_meta = FakeState.get(:fake_tmux_session_meta)
    prev_split_pane_exits = FakeState.get(:fake_tmux_split_pane_exits)

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
      restore_fake_state(:fake_tmux_test_pid, prev_test_pid)
      restore_fake_state(:fake_tmux_windows, prev_windows)
      restore_fake_state(:fake_tmux_panes, prev_panes)
      restore_fake_state(:fake_tmux_session_meta, prev_session_meta)
      restore_fake_state(:fake_tmux_split_pane_exits, prev_split_pane_exits)
      restore_app_env(:tmux_adapter, prev_tmux_adapter)

      if Process.whereis(FailingTmux) == self() do
        Process.unregister(FailingTmux)
      end
    end)

    :ok
  end

  test "pastes chunks in order and submits only the final chunk" do
    seed_agent_pane()

    assert {:ok, result} =
             AgentPromptSender.send_prompt(
               "devide_alpha_agent",
               "%2",
               "## Fix MCP auth\r\none\n\ntwo\nthree",
               max_lines_per_chunk: 2,
               submit: true
             )

    assert result == %{
             session: "devide_alpha_agent",
             pane: "%2",
             chunks_sent: 3,
             total_chunks: 3,
             max_lines_per_chunk: 2,
             max_bytes_per_chunk: 4_000,
             submit?: true,
             status: :done,
             title: "Fix MCP auth",
             title_source: :first_prompt,
             naming: %{
               session_alias: :set,
               pane_label: :skipped,
               window: :renamed,
               window_id: "@1",
               errors: []
             }
           }

    assert_receive {:fake_tmux_set_session_alias, "devide_alpha_agent", "Fix MCP auth"}
    assert_receive {:fake_tmux_rename_window, "devide_alpha_agent", "@1", "Fix MCP auth"}

    assert_receive {:fake_tmux_paste_text, "devide_alpha_agent", "%2", "## Fix MCP auth\none\n",
                    [target: "%2", submit: false]}

    assert_receive {:fake_tmux_paste_text, "devide_alpha_agent", "%2", "\ntwo\n",
                    [target: "%2", submit: false]}

    assert_receive {:fake_tmux_paste_text, "devide_alpha_agent", "%2", "three",
                    [target: "%2", submit: true]}

    assert_receive {:fake_tmux_keys, "devide_alpha_agent", "%2", "Enter", [target: "%2"]}
  end

  test "empty prompts do not submit or send chunks" do
    assert {:ok,
            %{
              chunks_sent: 0,
              total_chunks: 0,
              submit?: true,
              status: :noop,
              title: nil,
              title_source: :none,
              naming: %{
                session_alias: :skipped,
                pane_label: :skipped,
                window: :skipped,
                window_id: nil,
                errors: []
              }
            }} =
             AgentPromptSender.send_prompt("devide_alpha_agent", "%2", "", submit: true)

    refute_receive {:fake_tmux_paste_text, _, _, _, _}
    refute_receive {:fake_tmux_keys, _, _, _, _}
  end

  test "empty prompts record a searchable noop transition when workspace_id is provided" do
    Activity.subscribe("ws-alpha")

    assert {:ok,
            %{
              chunks_sent: 0,
              total_chunks: 0,
              status: :noop,
              title: nil,
              title_source: :none
            }} =
             AgentPromptSender.send_prompt("devide_alpha_agent", "%2", "",
               submit: true,
               workspace_id: "ws-alpha"
             )

    refute_receive {:fake_tmux_paste_text, _, _, _, _}
    refute_receive {:fake_tmux_keys, _, _, _, _}

    assert [
             %{
               action: "terminal.agent_prompt_noop",
               target_ref: "%2",
               metadata: metadata
             }
           ] = Audit.recent_for("ws-alpha", 5)

    assert metadata["session"] == "devide_alpha_agent"
    assert metadata["pane"] == "%2"
    assert metadata["tool"] == "send_agent_prompt"
    assert metadata["status"] == "noop"
    assert metadata["title_source"] == "none"
    assert metadata["chunks_sent"] == 0
    assert metadata["total_chunks"] == 0
    assert metadata["submit"] == true
    assert metadata["prompt_excerpt"] == ""
    assert metadata["prompt_truncated"] == false

    assert [
             %{
               tool: "send_agent_prompt",
               status: :ok,
               summary: summary,
               metadata: activity_metadata
             }
           ] = Activity.recent("ws-alpha", 5)

    assert summary =~ "noop: Untitled prompt"
    assert activity_metadata["status"] == "noop"
    assert activity_metadata["title_source"] == "none"

    assert_receive {:agent_mcp_activity,
                    %{
                      tool: "send_agent_prompt",
                      status: :ok,
                      metadata: %{"title_source" => "none", "status" => "noop"}
                    }}
  end

  test "stops on paste failure and reports attention metadata" do
    Process.register(self(), FailingTmux)

    assert {:error, error} =
             AgentPromptSender.send_prompt(
               "devide_alpha_agent",
               "%2",
               "ok\nfail\nlater",
               max_lines_per_chunk: 1,
               submit: true,
               tmux: FailingTmux
             )

    assert error == %{
             session: "devide_alpha_agent",
             pane: "%2",
             reason: :paste_failed,
             chunks_sent: 1,
             failed_chunk: 2,
             total_chunks: 3,
             max_lines_per_chunk: 1,
             max_bytes_per_chunk: 4_000,
             submit?: true,
             status: :attention,
             title: "ok",
             title_source: :first_prompt,
             naming: %{
               session_alias: :skipped,
               pane_label: :skipped,
               window: :skipped,
               window_id: nil,
               errors: []
             }
           }

    assert_receive {:failing_tmux_paste_text, "devide_alpha_agent", "ok\n",
                    [target: "%2", submit: false]}

    assert_receive {:failing_tmux_paste_text, "devide_alpha_agent", "fail\n",
                    [target: "%2", submit: false]}

    refute_receive {:failing_tmux_paste_text, "devide_alpha_agent", "later", _}
  end

  test "terminal facade uses the configured tmux adapter" do
    assert {:ok, %{chunks_sent: 1, title: "Run focused tests"}} =
             Terminals.send_agent_prompt(
               "devide_alpha_agent",
               "%2",
               "Run focused tests",
               submit: false
             )

    assert_receive {:fake_tmux_paste_text, "devide_alpha_agent", "%2", "Run focused tests",
                    [target: "%2", submit: false]}
  end

  test "terminal facade can resolve and target the agent pane" do
    seed_agent_pane()

    assert {:ok, %{id: "%2", agent_match: "pane_role"}} =
             Terminals.find_agent_pane("devide_alpha_agent")

    assert {:ok, %{pane: "%2", title: "Facade prompt"}} =
             Terminals.send_agent_prompt_to_agent_pane(
               "devide_alpha_agent",
               "Facade prompt",
               submit: false
             )

    assert_receive {:fake_tmux_paste_text, "devide_alpha_agent", "%2", "Facade prompt",
                    [target: "%2", submit: false]}
  end

  test "keeps existing session alias and human-named window" do
    seed_agent_pane(window_name: "human-review", session_alias: "Existing title")

    assert {:ok,
            %{
              naming: %{
                session_alias: :kept,
                pane_label: :skipped,
                window: :kept,
                window_id: "@1",
                errors: []
              }
            }} =
             AgentPromptSender.send_prompt(
               "devide_alpha_agent",
               "%2",
               "New prompt title",
               submit: false
             )

    refute_receive {:fake_tmux_set_session_alias, _, _}
    refute_receive {:fake_tmux_rename_window, _, _, _}
  end

  test "does not rename non-agent panes by default" do
    seed_agent_pane(pane_role: "operator")

    assert {:ok,
            %{
              naming: %{
                session_alias: :set,
                pane_label: :skipped,
                window: :skipped,
                window_id: "@1",
                errors: []
              }
            }} =
             AgentPromptSender.send_prompt(
               "devide_alpha_agent",
               "%2",
               "Operator pane prompt",
               submit: false
             )

    assert_receive {:fake_tmux_set_session_alias, "devide_alpha_agent", "Operator pane prompt"}
    refute_receive {:fake_tmux_rename_window, _, _, _}
  end

  test "send_to_agent_pane targets the role-marked agent pane" do
    seed_agent_pane()

    assert {:ok, %{pane: "%2", title: "Use agent role"}} =
             AgentPromptSender.send_to_agent_pane(
               "devide_alpha_agent",
               "Use agent role",
               submit: false
             )

    assert_receive {:fake_tmux_paste_text, "devide_alpha_agent", "%2", "Use agent role",
                    [target: "%2", submit: false]}
  end

  test "send_to_agent_pane fails clearly when no role-marked pane exists" do
    seed_agent_pane(pane_role: "operator")

    assert {:error,
            %{
              error: :agent_pane_not_found,
              message: "Apply the agent_pair template before using agent-pane tools.",
              suggested_template: "agent_pair",
              required_role: "agent",
              auto_apply_option: :auto_apply_agent_pair,
              candidate_panes: [%{id: "%2", role: "operator"}]
            }} =
             AgentPromptSender.send_to_agent_pane("devide_alpha_agent", "hello")

    refute_receive {:fake_tmux_paste_text, _, _, _, _}
  end

  test "send_to_agent_pane can auto-apply agent_pair before sending" do
    seed_agent_pane(pane_role: "operator")

    assert {:ok, %{pane: "%4", title: "Recover missing layout"}} =
             AgentPromptSender.send_to_agent_pane(
               "devide_alpha_agent",
               "Recover missing layout",
               submit: false,
               auto_apply_agent_pair: true
             )

    assert_receive {:fake_tmux_new_window, "devide_alpha_agent", opts}
    assert opts[:name] == "work"

    assert_receive {:fake_tmux_set_pane_role, "devide_alpha_agent", "%3", "operator"}
    assert_receive {:fake_tmux_split_pane, "devide_alpha_agent", "%3", "h", "%4"}
    assert_receive {:fake_tmux_set_pane_role, "devide_alpha_agent", "%4", "agent"}
    assert_receive {:fake_tmux_send_command, "devide_alpha_agent", "%4", _, _}

    assert_receive {:fake_tmux_paste_text, "devide_alpha_agent", "%4", "Recover missing layout",
                    [target: "%4", submit: false]}
  end

  test "send_to_agent_pane reports when auto-apply still leaves no agent pane" do
    seed_agent_pane(pane_role: "operator")
    FakeState.put(:fake_tmux_split_pane_exits, true)

    assert {:error,
            %{
              error: :agent_pane_not_found,
              auto_apply_agent_pair: :applied_no_agent_pane,
              suggested_template: "agent_pair",
              required_role: "agent",
              auto_apply_option: :auto_apply_agent_pair,
              candidate_panes: [
                %{id: "%2", role: "operator"},
                %{id: "%3", role: "operator"}
              ]
            }} =
             AgentPromptSender.send_to_agent_pane(
               "devide_alpha_agent",
               "Recover missing layout",
               auto_apply_agent_pair: true
             )

    refute_receive {:fake_tmux_paste_text, _, _, _, _}
  after
    FakeState.put(:fake_tmux_split_pane_exits, false)
  end

  test "records searchable title and status audit metadata when workspace_id is provided" do
    seed_agent_pane()
    Activity.subscribe("ws-alpha")

    assert {:ok, %{status: :done, title: "Fix preview auth"}} =
             AgentPromptSender.send_prompt(
               "devide_alpha_agent",
               "%2",
               "## Fix preview auth\r\nKeep blank lines\n\nThen run tests",
               max_lines_per_chunk: 2,
               submit: true,
               workspace_id: "ws-alpha",
               actor_id: "mcp"
             )

    assert [
             %{
               action: "terminal.agent_prompt_done",
               actor_id: "mcp",
               target_type: "tmux_pane",
               target_ref: "%2",
               metadata: metadata
             },
             %{
               action: "terminal.agent_prompt_running",
               actor_id: "mcp",
               target_type: "tmux_pane",
               target_ref: "%2",
               metadata: running_metadata
             }
           ] = Audit.recent_for("ws-alpha", 5)

    assert metadata["session"] == "devide_alpha_agent"
    assert metadata["pane"] == "%2"
    assert metadata["tool"] == "send_agent_prompt"
    assert metadata["status"] == "done"
    assert metadata["title"] == "Fix preview auth"
    assert metadata["title_source"] == "first_prompt"
    assert metadata["chunks_sent"] == 2
    assert metadata["total_chunks"] == 2
    assert metadata["max_bytes_per_chunk"] == 4_000
    assert metadata["submit"] == true
    assert metadata["prompt_excerpt"] == "## Fix preview auth\nKeep blank lines\n\nThen run tests"
    assert metadata["prompt_truncated"] == false
    assert metadata["naming"]["session_alias"] == "set"
    assert metadata["naming"]["pane_label"] == "set"
    assert metadata["naming"]["window"] == "renamed"

    assert running_metadata["status"] == "running"
    assert running_metadata["title"] == "Fix preview auth"
    assert running_metadata["title_source"] == "first_prompt"
    assert running_metadata["chunks_sent"] == 0
    assert running_metadata["total_chunks"] == 2
    assert running_metadata["naming"]["session_alias"] == "skipped"
    assert running_metadata["naming"]["pane_label"] == "set"

    assert %{
             label: "Fix preview auth",
             source: :agent,
             tool: "send_agent_prompt",
             frozen?: false
           } = Labels.get("devide_alpha_agent", "%2")

    assert [
             %{
               source: :terminal_mcp,
               tool: "send_agent_prompt",
               summary: summary,
               status: :ok,
               metadata: activity_metadata
             },
             %{
               source: :terminal_mcp,
               tool: "send_agent_prompt",
               summary: running_summary,
               status: :ok,
               metadata: running_activity_metadata
             }
           ] = Activity.recent("ws-alpha", 5)

    assert summary =~ "done: Fix preview auth"
    assert summary =~ "pane=%2"
    assert activity_metadata["session"] == "devide_alpha_agent"
    assert activity_metadata["pane"] == "%2"
    assert activity_metadata["title"] == "Fix preview auth"
    assert activity_metadata["title_source"] == "first_prompt"
    assert activity_metadata["status"] == "done"
    assert activity_metadata["prompt_excerpt"] == metadata["prompt_excerpt"]

    assert running_summary =~ "running: Fix preview auth"
    assert running_activity_metadata["title_source"] == "first_prompt"
    assert running_activity_metadata["status"] == "running"

    assert_receive {:agent_mcp_activity,
                    %{
                      tool: "send_agent_prompt",
                      status: :ok,
                      metadata: %{"title_source" => "first_prompt", "status" => "running"}
                    }}

    assert_receive {:agent_mcp_activity,
                    %{
                      tool: "send_agent_prompt",
                      status: :ok,
                      metadata: %{"title_source" => "first_prompt", "status" => "done"}
                    }}
  end

  test "prompt title labels the pane without overwriting a frozen manual label" do
    seed_agent_pane()
    Labels.set_agent_label("ws-alpha", "devide_alpha_agent", "%2", "Pinned review", freeze: true)

    assert {:ok, %{naming: %{pane_label: :kept}}} =
             AgentPromptSender.send_prompt(
               "devide_alpha_agent",
               "%2",
               "New prompt title",
               workspace_id: "ws-alpha"
             )

    assert %{label: "Pinned review", frozen?: true} = Labels.get("devide_alpha_agent", "%2")
  end

  test "redacts obvious secrets from derived names audit and activity" do
    seed_agent_pane()

    prompt = "Bearer abc123\nRun token=secret-value and DATABASE_URL=postgres://u:p@db/app"

    assert {:ok, %{title: "Bearer [REDACTED]"}} =
             AgentPromptSender.send_prompt(
               "devide_alpha_agent",
               "%2",
               prompt,
               workspace_id: "ws-alpha"
             )

    assert_receive {:fake_tmux_set_session_alias, "devide_alpha_agent", "Bearer [REDACTED]"}
    assert_receive {:fake_tmux_rename_window, "devide_alpha_agent", "@1", "Bearer [REDACTED]"}
    assert_receive {:fake_tmux_paste_text, "devide_alpha_agent", "%2", ^prompt, _opts}

    assert %{label: "Bearer [REDACTED]", tool: "send_agent_prompt"} =
             Labels.get("devide_alpha_agent", "%2")

    [%{metadata: audit_metadata} | _] = Audit.recent_for("ws-alpha", 5)

    assert audit_metadata["title"] == "Bearer [REDACTED]"
    assert audit_metadata["prompt_excerpt"] =~ "Bearer [REDACTED]"
    assert audit_metadata["prompt_excerpt"] =~ "token=[REDACTED]"
    assert audit_metadata["prompt_excerpt"] =~ "DATABASE_URL=[REDACTED]"
    refute inspect(audit_metadata) =~ "abc123"
    refute inspect(audit_metadata) =~ "secret-value"
    refute inspect(audit_metadata) =~ "postgres://u:p"

    [%{summary: summary, metadata: activity_metadata} | _] = Activity.recent("ws-alpha", 5)

    assert summary =~ "done: Bearer [REDACTED]"
    refute summary =~ "abc123"
    refute inspect(activity_metadata) =~ "secret-value"
  end

  test "records attention audit metadata when prompt sending fails" do
    Process.register(self(), FailingTmux)

    assert {:error, %{status: :attention}} =
             AgentPromptSender.send_prompt(
               "devide_alpha_agent",
               "%2",
               "ok\nfail\nlater",
               max_lines_per_chunk: 1,
               tmux: FailingTmux,
               workspace_id: "ws-alpha"
             )

    assert [
             %{
               action: "terminal.agent_prompt_attention",
               target_ref: "%2",
               metadata: metadata
             },
             %{
               action: "terminal.agent_prompt_running",
               target_ref: "%2",
               metadata: running_metadata
             }
           ] = Audit.recent_for("ws-alpha", 5)

    assert metadata["status"] == "attention"
    assert metadata["reason"] == "paste_failed"
    assert metadata["chunks_sent"] == 1
    assert metadata["failed_chunk"] == 2
    assert metadata["title"] == "ok"
    assert running_metadata["status"] == "running"
    assert running_metadata["title"] == "ok"
    assert running_metadata["chunks_sent"] == 0

    assert [
             %{
               tool: "send_agent_prompt",
               status: :error,
               summary: summary,
               metadata: activity_metadata
             },
             %{
               tool: "send_agent_prompt",
               status: :ok,
               summary: running_summary,
               metadata: running_activity_metadata
             }
           ] = Activity.recent("ws-alpha", 5)

    assert summary =~ "attention: ok"
    assert activity_metadata["status"] == "attention"
    assert activity_metadata["reason"] == "paste_failed"
    assert running_summary =~ "running: ok"
    assert running_activity_metadata["status"] == "running"
  end

  defp seed_agent_pane(opts \\ []) do
    session = "devide_alpha_agent"
    window_name = Keyword.get(opts, :window_name, "work")
    pane_role = Keyword.get(opts, :pane_role, "agent")

    FakeState.put(:fake_tmux_windows, %{
      session => [
        %{
          id: "@1",
          index: 0,
          name: window_name,
          active: true,
          panes: 1,
          activity: 0,
          current_command: "bash"
        }
      ]
    })

    FakeState.put(:fake_tmux_panes, %{
      session => [
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

    if session_alias = Keyword.get(opts, :session_alias) do
      FakeState.put(:fake_tmux_session_meta, %{session => %{session_alias: session_alias}})
    end
  end

  defp restore_fake_state(key, nil), do: FakeState.delete(key)
  defp restore_fake_state(key, value), do: FakeState.put(key, value)

  defp restore_app_env(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore_app_env(key, value), do: Application.put_env(:dev_ide, key, value)
end
