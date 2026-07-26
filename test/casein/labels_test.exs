defmodule Casein.LabelsTest do
  use Casein.TestCase, async: false

  alias Casein.Labels

  setup do
    Labels.clear()

    on_exit(fn ->
      Labels.clear()
    end)

    :ok
  end

  test "stores and broadcasts pane labels keyed by tmux session and pane" do
    :ok = Labels.subscribe("ws-labels")

    Labels.set_agent_label("ws-labels", "casein_alpha_u-dev", "%3", "mix test", freeze: true)

    assert_receive {:pane_label_updated, "casein_alpha_u-dev", "%3", entry}
    assert entry.label == "mix test"
    assert entry.frozen? == true
    assert Labels.get("casein_alpha_u-dev", "%3").label == "mix test"

    assert Labels.key("casein_alpha_u-dev", "%3") in Map.keys(
             Labels.for_session("casein_alpha_u-dev")
           )
  end

  test "stores optional label tool metadata" do
    Labels.set_agent_label("ws-labels", "casein_alpha_u-dev", "%3", "Fix MCP auth",
      tool: "send_agent_prompt"
    )

    assert %{label: "Fix MCP auth", source: :agent, tool: "send_agent_prompt"} =
             Labels.get("casein_alpha_u-dev", "%3")
  end

  test "propose_from_mcp uses invoke result target pane" do
    :ok = Labels.subscribe("ws-labels")

    Labels.propose_from_mcp(
      "ws-labels",
      "terminal_send_agent_command",
      %{"command" => "mix precommit"},
      {:ok, %{session: "casein_alpha_u-dev", target: "%3", status: "sent"}}
    )

    assert_receive {:pane_label_updated, "casein_alpha_u-dev", "%3", %{label: "mix precommit"}}
  end

  test "debounces rapid MCP label changes" do
    Labels.propose_from_mcp(
      "ws-labels",
      "terminal_send_command",
      %{"session" => "casein_alpha_u-dev", "pane" => "%3", "command" => "mix test"},
      :ok
    )

    assert %{label: "mix test"} = Labels.get("casein_alpha_u-dev", "%3")

    Labels.propose_from_mcp(
      "ws-labels",
      "terminal_send_command",
      %{"session" => "casein_alpha_u-dev", "pane" => "%3", "command" => "mix format"},
      :ok
    )

    assert Labels.get("casein_alpha_u-dev", "%3").label == "mix test"
  end

  test "mark_quiet appends suffix and clear_quiet restores base label" do
    Labels.set_agent_label("ws-labels", "casein_alpha_u-dev", "%3", "mix test")

    Labels.mark_quiet("ws-labels", "casein_alpha_u-dev", "%3")
    assert Labels.get("casein_alpha_u-dev", "%3").label == "mix test · quiet"

    Labels.clear_quiet("ws-labels", "casein_alpha_u-dev", "%3")
    assert Labels.get("casein_alpha_u-dev", "%3").label == "mix test"
  end

  test "prune_session drops labels for removed panes" do
    Labels.set_agent_label("ws-labels", "casein_alpha_u-dev", "%3", "one")
    Labels.set_agent_label("ws-labels", "casein_alpha_u-dev", "%4", "two")

    Labels.prune_session("casein_alpha_u-dev", ["%3"])

    assert Labels.get("casein_alpha_u-dev", "%3")
    refute Labels.get("casein_alpha_u-dev", "%4")
  end
end
