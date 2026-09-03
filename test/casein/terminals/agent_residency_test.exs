defmodule Casein.Terminals.AgentResidencyTest do
  use ExUnit.Case, async: true

  alias Casein.Terminals.AgentResidency
  alias Casein.Terminals.HostCapacity

  # pid 200 is a pane shell; 400 is a plain shell under it.
  @listing """
  milc 100 1 /usr/bin/tmux
  milc 200 100 -bash
  milc 300 200 /usr/local/bin/claude
  milc 400 200 /bin/sh
  milc 401 400 /usr/bin/opencode
  milc 500 1 /usr/local/bin/codex
  milc 600 999 /usr/bin/grok
  milc 700 200 /usr/bin/vim
  """

  @panes %{"200" => %{session: "work", pane_id: "%1"}}

  defp resident(report, pid), do: Enum.find(report.residents, &(&1.pid == pid))

  describe "classify/2" do
    test "counts every agent HostCapacity counts, and no one else" do
      report = AgentResidency.classify(@listing, @panes)

      assert report.total == HostCapacity.count_agents(@listing)
      assert Enum.map(report.residents, & &1.pid) == ~w(300 401 500 600)
    end

    test "an agent whose parent is the pane shell is in that pane" do
      report = AgentResidency.classify(@listing, @panes)

      assert %{residency: :in_pane, pane: %{session: "work", pane_id: "%1"}} =
               resident(report, "300")
    end

    test "an agent below an intermediate shell is still in the pane" do
      # 401 -> 400 -> 200: matching the agent's own pid against pane_pid would
      # miss this one, which is why the walk exists.
      report = AgentResidency.classify(@listing, @panes)

      assert %{residency: :in_pane, pane: %{pane_id: "%1"}} = resident(report, "401")
    end

    test "an agent reparented to init has no pane and is flagged an orphan" do
      report = AgentResidency.classify(@listing, @panes)

      assert %{residency: :no_pane, pane: nil, orphan?: true, ppid: "1"} =
               resident(report, "500")
    end

    test "an agent whose parent is not in the listing has no pane" do
      report = AgentResidency.classify(@listing, @panes)

      assert %{residency: :no_pane, pane: nil, orphan?: false} = resident(report, "600")
    end

    test "an agent running as the pane command is its own pane" do
      listing = "milc 200 100 /usr/local/bin/claude\n"

      report = AgentResidency.classify(listing, @panes)

      assert %{residency: :in_pane, pane: %{pane_id: "%1"}} = resident(report, "200")
    end

    test "with no panes at all, every agent is unreachable" do
      report = AgentResidency.classify(@listing, %{})

      assert report.no_pane == report.total
      assert report.in_pane == 0
    end

    test "totals add up and orphans are counted separately" do
      report = AgentResidency.classify(@listing, @panes)

      assert report.total == 4
      assert report.in_pane == 2
      assert report.no_pane == 2
      assert report.orphans == 1
      assert report.in_pane + report.no_pane == report.total
    end

    test "a self-parenting pid terminates the walk instead of looping" do
      # A cycle would hang the report; the walk must stop and report :no_pane.
      report = AgentResidency.classify("milc 800 800 /usr/bin/claude\n", @panes)

      assert %{residency: :no_pane} = resident(report, "800")
    end

    test "a parent chain deeper than the guard stops rather than recursing forever" do
      # 100 links, each parented to the next, rooted at the pane shell — the
      # depth guard trips before reaching it.
      listing =
        Enum.map_join(1..100, "", fn n -> "milc #{1000 + n} #{1001 + n} /bin/sh\n" end) <>
          "milc 1101 200 /bin/sh\nmilc 1001 1002 /usr/bin/claude\n"

      report = AgentResidency.classify(listing, @panes)

      assert %{residency: :no_pane} = resident(report, "1001")
    end
  end

  describe "report/1" do
    test "injected inputs skip both probes and classify them" do
      assert {:ok, report} = AgentResidency.report(listing: @listing, panes: @panes)

      assert report.total == 4
      assert report.no_pane == 2
    end

    test "reads every pane on the server, not one session's" do
      runner = fn argv ->
        send(self(), {:argv, argv})
        {"work|%1|200\nidle|%7|900\nmalformed-line\n", 0}
      end

      assert {:ok, report} = AgentResidency.report(listing: @listing, runner: runner)

      assert_received {:argv, argv}
      assert "-a" in argv
      assert report.in_pane == 2
    end

    test "a tmux server that will not answer means no panes, not a crash" do
      runner = fn _argv -> {"no server running", 1} end

      assert {:ok, %{in_pane: 0, no_pane: 4}} =
               AgentResidency.report(listing: @listing, runner: runner)
    end
  end

  describe "HostCapacity.agent_sessions/1" do
    test "carries the command and stays in step with count_agents/1" do
      sessions = HostCapacity.agent_sessions(@listing)

      assert length(sessions) == HostCapacity.count_agents(@listing)
      assert Enum.map(sessions, & &1.command) == ~w(claude opencode codex grok)
    end

    test "still drops an agent whose parent is itself an agent" do
      listing = "milc 300 200 /usr/local/bin/claude\nmilc 301 300 /usr/local/bin/claude\n"

      assert [%{pid: "300"}] = HostCapacity.agent_sessions(listing)
    end
  end

  describe "process_parents/1" do
    test "maps each pid to its parent and ignores malformed lines" do
      parents = HostCapacity.process_parents(@listing <> "garbage\n")

      assert parents["401"] == "400"
      assert parents["500"] == "1"
      refute Map.has_key?(parents, "garbage")
    end
  end
end
