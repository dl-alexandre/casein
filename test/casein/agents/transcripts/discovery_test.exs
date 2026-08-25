defmodule Casein.Agents.Transcripts.DiscoveryTest do
  use ExUnit.Case, async: true

  alias Casein.Agents.Transcripts.Discovery

  setup do
    root = Path.join(System.tmp_dir!(), "discovery-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  describe "project_slug/1" do
    test "mirrors Claude's directory naming" do
      assert Discovery.project_slug("/data/casein-agent-worktrees/wt-a") ==
               "-data-casein-agent-worktrees-wt-a"
    end

    test "dots become dashes, so hidden directories round-trip" do
      # Observed on the box: /home/devbox/.devide-agent-mcp/x
      assert Discovery.project_slug("/home/devbox/.devide-agent-mcp/x") ==
               "-home-devbox--devide-agent-mcp-x"
    end

    test "relative paths are expanded before slugging" do
      slug = Discovery.project_slug(".")
      assert String.starts_with?(slug, "-")
      refute String.contains?(slug, "/")
    end
  end

  describe "resolve/3" do
    test "finds the one live session for a cwd", %{root: root} do
      cwd = "/data/worktrees/wt-a"
      path = session!(root, cwd, "live.jsonl")

      assert {:ok, ^path} = Discovery.resolve(cwd, [root])
    end

    test "a cwd with no project directory is not a missing session", %{root: root} do
      assert {:error, :no_transcript_dir} = Discovery.resolve("/data/worktrees/never", [root])
    end

    test "a directory of finished sessions is distinguishable from a missing one", %{root: root} do
      cwd = "/data/worktrees/wt-b"
      path = session!(root, cwd, "old.jsonl")
      backdate!(path, 4_000)

      assert {:error, :no_live_transcript} = Discovery.resolve(cwd, [root])
    end

    test "two live sessions in one worktree are refused, not guessed", %{root: root} do
      # The trap this rule exists for: attributing a neighbour's conversation to
      # this pane would show a busy agent as waiting.
      cwd = "/data/worktrees/shared"
      session!(root, cwd, "agent-a.jsonl")
      session!(root, cwd, "agent-b.jsonl")

      assert {:error, :ambiguous} = Discovery.resolve(cwd, [root])
    end

    test "a finished session does not make a live one ambiguous", %{root: root} do
      cwd = "/data/worktrees/wt-c"
      stale = session!(root, cwd, "yesterday.jsonl")
      live = session!(root, cwd, "today.jsonl")
      backdate!(stale, 90_000)

      assert {:ok, ^live} = Discovery.resolve(cwd, [root])
    end

    test "non-jsonl entries in the directory are ignored", %{root: root} do
      cwd = "/data/worktrees/wt-d"
      path = session!(root, cwd, "live.jsonl")
      File.write!(Path.join(Path.dirname(path), "notes.md"), "x")
      File.mkdir_p!(Path.join(Path.dirname(path), "subdir"))

      assert {:ok, ^path} = Discovery.resolve(cwd, [root])
    end

    test "earlier roots win, so an owner profile is never shadowed", %{root: root} do
      cwd = "/data/worktrees/wt-e"
      profile = Path.join(root, "profile")
      global = Path.join(root, "global")
      owned = session!(profile, cwd, "owned.jsonl")
      session!(global, cwd, "global.jsonl")

      assert {:ok, ^owned} = Discovery.resolve(cwd, [profile, global])
    end

    test "the global root is used when the profile has nothing", %{root: root} do
      cwd = "/data/worktrees/wt-f"
      profile = Path.join(root, "profile")
      global = Path.join(root, "global")
      File.mkdir_p!(profile)
      fallback = session!(global, cwd, "global.jsonl")

      assert {:ok, ^fallback} = Discovery.resolve(cwd, [profile, global])
    end

    test "a blank cwd is an error rather than a wildcard", %{root: root} do
      assert {:error, :no_cwd} = Discovery.resolve(nil, [root])
      assert {:error, :no_cwd} = Discovery.resolve("", [root])
    end

    test "resolve_session finds the file named for the session id", %{root: root} do
      cwd = "/data/worktrees/wt-session"
      path = session!(root, cwd, "abc-123.jsonl")
      session!(root, cwd, "other.jsonl")

      assert {:ok, ^path} = Discovery.resolve_session(cwd, "abc-123", [root])
    end

    test "resolve_session is path_missing when the id is absent", %{root: root} do
      cwd = "/data/worktrees/wt-missing"
      session!(root, cwd, "other.jsonl")

      assert {:error, :path_missing} = Discovery.resolve_session(cwd, "abc-123", [root])
    end

    test "resolve_session rejects traversal in the session id", %{root: root} do
      assert {:error, :invalid_session_id} =
               Discovery.resolve_session("/data/worktrees/wt-x", "../secret", [root])
    end

    test "the live window is caller-tunable", %{root: root} do
      cwd = "/data/worktrees/wt-g"
      path = session!(root, cwd, "recent.jsonl")
      backdate!(path, 600)

      assert {:error, :no_live_transcript} =
               Discovery.resolve(cwd, [root], live_window_seconds: 60)

      assert {:ok, ^path} = Discovery.resolve(cwd, [root], live_window_seconds: 3_600)
    end
  end

  ## Fixtures

  defp session!(root, cwd, name) do
    dir = Path.join(root, Discovery.project_slug(cwd))
    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, "{}\n")
    path
  end

  defp backdate!(path, seconds) do
    File.touch!(path, System.os_time(:second) - seconds)
  end
end
