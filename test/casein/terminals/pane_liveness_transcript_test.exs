defmodule Casein.Terminals.PaneLivenessTranscriptTest do
  # Not async: transcript discovery resolves paths under $HOME.
  use ExUnit.Case, async: false

  alias Casein.Terminals.PaneLiveness

  setup do
    previous_home = System.get_env("HOME")
    home = Path.join(System.tmp_dir!(), "pane-transcript-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    System.put_env("HOME", home)

    on_exit(fn ->
      if previous_home,
        do: System.put_env("HOME", previous_home),
        else: System.delete_env("HOME")

      File.rm_rf(home)
    end)

    %{home: home}
  end

  describe "transcript enrichment" do
    test "an agent pane whose transcript went quiet on prose is awaiting input", %{home: home} do
      cwd = Path.join(home, "wt-a")
      File.mkdir_p!(cwd)
      transcript!(home, cwd, [assistant_prose("Done — want me to push?")])

      assert %{panes: [pane]} =
               PaneLiveness.enrich_topology(topology([pane("%1", cwd)]),
                 liveness: false,
                 transcript: true,
                 silence_seconds: 0
               )

      assert pane.transcript.state == :awaiting_input
      assert pane.transcript.last_shape == :assistant_prose
      assert pane.transcript.transcript_path =~ ".claude/projects/"
    end

    test "an outstanding tool call is working, not waiting", %{home: home} do
      cwd = Path.join(home, "wt-b")
      File.mkdir_p!(cwd)
      transcript!(home, cwd, [assistant_prose("ok"), assistant_tool_call("Bash")])

      assert %{panes: [pane]} =
               PaneLiveness.enrich_topology(topology([pane("%1", cwd)]),
                 liveness: false,
                 transcript: true,
                 silence_seconds: 0
               )

      assert pane.transcript.state == :working
    end

    test "a plain shell in an agent's worktree never inherits its conversation", %{home: home} do
      # The false positive `agent_panes_only` exists to prevent: an operator
      # shell sitting beside the agent would otherwise read as waiting.
      cwd = Path.join(home, "wt-c")
      File.mkdir_p!(cwd)
      transcript!(home, cwd, [assistant_prose("waiting on you")])

      panes = [pane("%1", cwd), pane("%2", cwd, role: "shell")]

      assert %{panes: [agent, shell]} =
               PaneLiveness.enrich_topology(topology(panes),
                 liveness: false,
                 transcript: true,
                 silence_seconds: 0
               )

      assert agent.transcript.state == :awaiting_input
      refute Map.has_key?(shell, :transcript)
    end

    test "two live sessions in one worktree report why, rather than guessing", %{home: home} do
      cwd = Path.join(home, "wt-d")
      File.mkdir_p!(cwd)
      transcript!(home, cwd, [assistant_prose("a")], "agent-a.jsonl")
      transcript!(home, cwd, [assistant_tool_call("Bash")], "agent-b.jsonl")

      assert %{panes: [pane]} =
               PaneLiveness.enrich_topology(topology([pane("%1", cwd)]),
                 liveness: false,
                 transcript: true,
                 silence_seconds: 0
               )

      assert pane.transcript == %{state: :unknown, reason: :ambiguous}
    end

    test "a pane with no transcript reports the reason instead of vanishing", %{home: home} do
      cwd = Path.join(home, "wt-e")
      File.mkdir_p!(cwd)

      assert %{panes: [pane]} =
               PaneLiveness.enrich_topology(topology([pane("%1", cwd)]),
                 liveness: false,
                 transcript: true
               )

      assert pane.transcript.state == :unknown
      assert pane.transcript.reason == :no_transcript_dir
    end

    test "an owner's auth profile is searched before the host global login", %{home: home} do
      # On a shared box each owner has their own Claude home. Searching the
      # global login first would hand one owner another's conversation.
      cwd = Path.join(home, "wt-owned")
      File.mkdir_p!(cwd)
      auth_root = Path.join([home, ".casein", "agent-auth"])
      profile = Path.join([auth_root, "profiles", "someone", "claude"])

      # `allowed_path?/1` gates on the configured auth root, so this test owns
      # that config rather than inheriting whatever ran before it.
      previous = Application.get_env(:casein, :agent_auth_profile_root)
      Application.put_env(:casein, :agent_auth_profile_root, auth_root)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:casein, :agent_auth_profile_root, previous),
          else: Application.delete_env(:casein, :agent_auth_profile_root)
      end)

      owned = transcript!(profile, cwd, [assistant_prose("owner session")])
      transcript!(home, cwd, [assistant_tool_call("Bash")])

      assert %{panes: [pane]} =
               PaneLiveness.enrich_topology(topology([pane("%1", cwd)]),
                 liveness: false,
                 transcript: true,
                 silence_seconds: 0,
                 claude_home: profile
               )

      assert pane.transcript.transcript_path == owned
      assert pane.transcript.state == :awaiting_input
    end

    test "enrichment is off by default, so no caller pays for it unasked", %{home: home} do
      cwd = Path.join(home, "wt-f")
      File.mkdir_p!(cwd)
      transcript!(home, cwd, [assistant_prose("waiting")])

      assert %{panes: [pane]} =
               PaneLiveness.enrich_topology(topology([pane("%1", cwd)]), liveness: false)

      refute Map.has_key?(pane, :transcript)
    end
  end

  ## Fixtures

  defp topology(panes), do: %{panes: panes, windows: []}

  defp pane(id, current_path, opts \\ []) do
    %{id: id, current_path: current_path, role: Keyword.get(opts, :role, "agent")}
  end

  # `root` is either a $HOME (whose Claude home is `.claude`) or an already
  # resolved provider home, matching what `AuthProfile.active_profile_dir/2`
  # hands back.
  defp transcript!(root, cwd, entries, name \\ "session.jsonl") do
    slug = Casein.Agents.Transcripts.Discovery.project_slug(cwd)

    dir =
      if Path.basename(root) == "claude",
        do: Path.join([root, "projects", slug]),
        else: Path.join([root, ".claude", "projects", slug])

    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, Enum.map_join(entries, "", &(Jason.encode!(&1) <> "\n")))
    path
  end

  defp assistant_prose(text) do
    %{
      "type" => "assistant",
      "message" => %{"role" => "assistant", "content" => [%{"type" => "text", "text" => text}]}
    }
  end

  defp assistant_tool_call(name) do
    %{
      "type" => "assistant",
      "message" => %{
        "role" => "assistant",
        "content" => [%{"type" => "tool_use", "name" => name, "input" => %{}}]
      }
    }
  end
end
