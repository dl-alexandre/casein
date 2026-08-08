defmodule Casein.Terminals.NextPromptTest do
  use Casein.TestCase, async: false

  alias Casein.Terminals.AgentState
  alias Casein.Terminals.NextPrompt

  @session "casein_alpha_next"
  @pane "%4"

  setup do
    prev_deliver = Application.get_env(:casein, :next_prompt_deliver)
    test_pid = self()

    # Delivery normally pastes into tmux and polls the pane. Here it only
    # reports what it was handed, so these tests assert scheduling — which
    # message, on which edge — and leave transport to PaneSubmitTest.
    Application.put_env(:casein, :next_prompt_deliver, fn entry, trigger ->
      send(test_pid, {:delivered, entry, trigger})
      {:ok, %{delivery: :delivered}}
    end)

    NextPrompt.clear()
    AgentState.clear()

    on_exit(fn ->
      NextPrompt.clear()
      AgentState.clear()

      if prev_deliver,
        do: Application.put_env(:casein, :next_prompt_deliver, prev_deliver),
        else: Application.delete_env(:casein, :next_prompt_deliver)
    end)

    :ok
  end

  defp ws, do: "ws-next-#{System.unique_integer([:positive])}"

  defp stage(workspace_id, text, opts \\ []) do
    NextPrompt.set(
      @session,
      @pane,
      text,
      Keyword.merge([workspace_id: workspace_id, current_state: :working], opts)
    )
  end

  describe "target_states/1" do
    test "next_idle covers done as well as idle" do
      # Claude's hook only emits `idle` at SessionStart/SessionEnd, so a literal
      # reading of the default deliver_when would almost never fire.
      assert NextPrompt.target_states(:next_idle) == [:idle, :done]
      assert NextPrompt.target_states(:next_done) == [:done]
      assert NextPrompt.target_states(:next_blocked) == [:blocked]
    end
  end

  describe "parse_deliver_when/1" do
    test "defaults when absent and rejects unknown values" do
      assert NextPrompt.parse_deliver_when(nil) == {:ok, :next_idle}
      assert NextPrompt.parse_deliver_when("next_done") == {:ok, :next_done}
      assert NextPrompt.parse_deliver_when("blocked") == :error
      assert NextPrompt.parse_deliver_when("whenever") == :error
    end
  end

  describe "set/4 coalescing" do
    test "a second message replaces the first — the slot holds one, latest wins" do
      workspace = ws()

      assert {:ok, %{status: :pending}} = stage(workspace, "rebase first", coalesce_key: "orch")

      assert {:ok, %{status: :pending, replaced: replaced}} =
               stage(workspace, "actually, just push", coalesce_key: "orch")

      assert replaced.text == "rebase first"
      assert NextPrompt.get(@session, @pane).text == "actually, just push"
      assert map_size(NextPrompt.for_session(@session)) == 1
    end

    test "a different coalesce_key still replaces — the key is identity, not a partition" do
      workspace = ws()

      {:ok, _} = stage(workspace, "from orchestrator A", coalesce_key: "a")
      {:ok, %{replaced: replaced}} = stage(workspace, "from orchestrator B", coalesce_key: "b")

      assert replaced.coalesce_key == "a"
      assert NextPrompt.get(@session, @pane).coalesce_key == "b"
    end

    test "rejects an empty message and an over-long one" do
      workspace = ws()

      assert {:error, :empty_next_prompt} = stage(workspace, "   ")

      assert {:error, {:next_prompt_too_long, _limit}} =
               stage(workspace, String.duplicate("x", NextPrompt.text_limit() + 1))
    end

    test "an unknown deliver_when is refused rather than silently defaulted" do
      assert {:error, :invalid_deliver_when} =
               NextPrompt.set(@session, @pane, "hi",
                 workspace_id: ws(),
                 deliver_when: "next_finished"
               )
    end
  end

  describe "delivery on state edge" do
    test "waits through working and fires on the first quiescent edge" do
      workspace = ws()
      {:ok, %{status: :pending}} = stage(workspace, "rebase before you push")

      AgentState.report(workspace, @session, @pane, :working, "still going")
      refute_receive {:delivered, _entry, _trigger}, 200

      AgentState.report(workspace, @session, @pane, :done, "turn complete")

      assert_receive {:delivered, entry, :done}, 1_000
      assert entry.text == "rebase before you push"
      assert NextPrompt.get(@session, @pane) == nil
    end

    test "next_blocked ignores done and fires on blocked" do
      workspace = ws()
      {:ok, _} = stage(workspace, "approve it", deliver_when: "next_blocked")

      AgentState.report(workspace, @session, @pane, :done, nil)
      refute_receive {:delivered, _entry, _trigger}, 200

      AgentState.report(workspace, @session, @pane, :blocked, "needs permission")
      assert_receive {:delivered, _entry, :blocked}, 1_000
    end

    test "next_done ignores idle" do
      workspace = ws()
      {:ok, _} = stage(workspace, "ship it", deliver_when: "next_done")

      AgentState.report(workspace, @session, @pane, :idle, nil)
      refute_receive {:delivered, _entry, _trigger}, 200
      assert NextPrompt.get(@session, @pane)
    end

    test "delivers exactly once even when the edge is re-reported" do
      workspace = ws()
      {:ok, _} = stage(workspace, "one only")

      AgentState.report(workspace, @session, @pane, :done, "first")
      assert_receive {:delivered, _entry, :done}, 1_000

      AgentState.report(workspace, @session, @pane, :working, nil)
      AgentState.report(workspace, @session, @pane, :done, "second")
      refute_receive {:delivered, _entry, _trigger}, 300
    end

    test "delivers immediately when the pane is already in the requested state" do
      workspace = ws()

      assert {:ok, %{status: :delivered}} =
               stage(workspace, "you are free, do this", current_state: :idle)

      assert_receive {:delivered, entry, :immediate}, 1_000
      assert entry.text == "you are free, do this"
      assert NextPrompt.get(@session, @pane) == nil
    end
  end

  describe "dropping" do
    test "drops when the runtime session changes instead of delivering to a stranger" do
      workspace = ws()
      {:ok, _} = stage(workspace, "keep going", agent_session_id: "session-a")

      AgentState.report(workspace, @session, @pane, :done, nil, agent_session_id: "session-b")

      refute_receive {:delivered, _entry, _trigger}, 300
      assert NextPrompt.get(@session, @pane) == nil
    end

    test "a report with no session id is not evidence of a restart" do
      workspace = ws()
      {:ok, _} = stage(workspace, "keep going", agent_session_id: "session-a")

      AgentState.report(workspace, @session, @pane, :done, nil)

      assert_receive {:delivered, _entry, :done}, 1_000
    end

    test "an expired message is dropped on the edge that would have delivered it" do
      workspace = ws()

      {:ok, _} =
        stage(workspace, "too late", expires_at: DateTime.add(DateTime.utc_now(), -1, :second))

      AgentState.report(workspace, @session, @pane, :done, nil)

      refute_receive {:delivered, _entry, _trigger}, 300
      assert NextPrompt.get(@session, @pane) == nil
    end

    test "prune_session drops messages for panes that no longer exist" do
      workspace = ws()
      {:ok, _} = stage(workspace, "orphaned")

      NextPrompt.prune_session(@session, ["%1", "%2"])

      assert NextPrompt.get(@session, @pane) == nil
    end

    test "prune_session keeps messages for panes that are still alive" do
      workspace = ws()
      {:ok, _} = stage(workspace, "still addressed")

      NextPrompt.prune_session(@session, [@pane, "%9"])

      assert NextPrompt.get(@session, @pane)
    end
  end

  describe "clear/3" do
    test "clears unconditionally without a key" do
      workspace = ws()
      {:ok, _} = stage(workspace, "never mind", coalesce_key: "orch")

      assert %{text: "never mind"} = NextPrompt.clear(@session, @pane)
      assert NextPrompt.get(@session, @pane) == nil
    end

    test "a key mismatch leaves someone else's message alone" do
      workspace = ws()
      {:ok, _} = stage(workspace, "from B", coalesce_key: "b")

      assert NextPrompt.clear(@session, @pane, coalesce_key: "a") == nil
      assert NextPrompt.get(@session, @pane).text == "from B"

      assert %{text: "from B"} = NextPrompt.clear(@session, @pane, coalesce_key: "b")
    end

    test "clearing nothing is not an error" do
      assert NextPrompt.clear(@session, @pane) == nil
    end
  end

  describe "enrich_topology/2" do
    test "flags only panes with something pending" do
      workspace = ws()
      {:ok, _} = stage(workspace, "waiting", deliver_when: "next_done")

      topology = %{panes: [%{id: @pane}, %{id: "%5"}], windows: []}

      assert %{panes: [flagged, plain]} = NextPrompt.enrich_topology(topology, @session)
      assert flagged.pending_next_prompt == true
      assert flagged.pending_next_prompt_deliver_when == "next_done"
      refute Map.has_key?(plain, :pending_next_prompt)
    end

    test "leaves the topology untouched when nothing is staged" do
      topology = %{panes: [%{id: @pane}], windows: []}
      assert NextPrompt.enrich_topology(topology, @session) == topology
    end
  end
end
