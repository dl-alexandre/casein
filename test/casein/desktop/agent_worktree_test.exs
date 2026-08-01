defmodule Casein.Desktop.AgentWorktreeTest do
  use ExUnit.Case, async: true

  alias Casein.Desktop.AgentWorktree

  test "creates a branch worktree beneath a Windows-safe root" do
    fixture = fixture!()
    timestamp = ~U[2026-08-01 12:34:56Z]

    assert {:ok, result} =
             AgentWorktree.create(fixture.repo, "codex", "diagnose",
               root: fixture.worktrees,
               base_ref: "HEAD",
               timestamp: timestamp,
               suffix: 42
             )

    assert result.branch == "agent/codex/diagnose-20260801123456-42"
    assert Path.basename(Path.dirname(result.path)) == Path.basename(fixture.worktrees)
    assert File.dir?(result.path)
    assert File.regular?(Path.join(result.path, ".git"))

    on_exit(fn ->
      System.cmd("git", ["-C", fixture.repo, "worktree", "remove", result.path, "--force"])
      File.rm_rf(fixture.root)
    end)
  end

  test "rejects unsafe runtime, task, base ref, and nested roots before mutation" do
    fixture = fixture!()
    nested = Path.join(fixture.repo, "worktrees")

    assert {:error, :unsupported_agent} = AgentWorktree.create(fixture.repo, "codex;whoami")
    assert {:error, :invalid_task} = AgentWorktree.create(fixture.repo, "codex", "../escape")

    assert {:error, :invalid_base_ref} =
             AgentWorktree.create(fixture.repo, "codex", "safe",
               root: fixture.worktrees,
               base_ref: "HEAD;whoami"
             )

    assert {:error, :invalid_base_ref} =
             AgentWorktree.create(fixture.repo, "codex", "safe",
               root: fixture.worktrees,
               base_ref: "--help"
             )

    assert {:error, :invalid_branch_identity} =
             AgentWorktree.create(fixture.repo, "codex", "safe",
               root: fixture.worktrees,
               base_ref: "HEAD",
               suffix: "../escape"
             )

    assert {:error, :worktree_root_inside_repository} =
             AgentWorktree.create(fixture.repo, "codex", "safe", root: nested, base_ref: "HEAD")

    refute File.exists?(nested)
    File.rm_rf(fixture.root)
  end

  test "uses argv-only git calls with validated product-derived targets" do
    root = Path.join(System.tmp_dir!(), "agent worktrees #{System.unique_integer([:positive])}")
    parent = Path.join(System.tmp_dir!(), "primary repo #{System.unique_integer([:positive])}")
    normalized_parent = Path.expand(parent)

    runner = fn
      ["-C", ^parent, "rev-parse", "--show-toplevel"], [] ->
        {parent <> "\n", 0}

      ["-C", ^normalized_parent, "worktree", "add", "-b", branch, path, "HEAD"], [] ->
        send(self(), {:git_add, branch, path})
        {"", 0}
    end

    assert {:ok, result} =
             AgentWorktree.create(parent, "claude", "review",
               root: root,
               base_ref: "HEAD",
               timestamp: ~U[2026-08-01 01:02:03Z],
               suffix: 7,
               runner: runner
             )

    assert_received {:git_add, "agent/claude/review-20260801010203-7", path}
    assert path == result.path
    assert Path.basename(Path.dirname(path)) == Path.basename(root)
    File.rm_rf(root)
  end

  test "canonicalizes a linked worktree root before containment and creation" do
    fixture = fixture!()
    target = Path.join(fixture.root, "linked target")
    link = Path.join(fixture.root, "linked root")
    File.mkdir_p!(target)
    create_directory_link!(link, target)

    assert {:ok, result} =
             AgentWorktree.create(fixture.repo, "cursor", "review",
               root: Path.join(link, "children"),
               base_ref: "HEAD",
               timestamp: ~U[2026-08-01 01:02:03Z],
               suffix: 8
             )

    resolved_parent = File.stat!(Path.dirname(result.path))
    target_parent = File.stat!(Path.join(target, "children"))

    assert {resolved_parent.major_device, resolved_parent.inode} ==
             {target_parent.major_device, target_parent.inode}

    System.cmd("git", ["-C", fixture.repo, "worktree", "remove", result.path, "--force"])
  end

  defp fixture! do
    root = Path.join(System.tmp_dir!(), "native-worktree-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "primary repo")
    worktrees = Path.join(root, "agent worktrees")
    File.mkdir_p!(repo)
    git!(["init", "--initial-branch=master", repo])
    git!(["-C", repo, "config", "user.email", "casein@example.invalid"])
    git!(["-C", repo, "config", "user.name", "Casein Test"])
    File.write!(Path.join(repo, "README.md"), "fixture\n")
    git!(["-C", repo, "add", "README.md"])
    git!(["-C", repo, "commit", "-m", "fixture"])
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, repo: repo, worktrees: worktrees}
  end

  defp git!(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git failed (#{status}): #{output}")
    end
  end

  defp create_directory_link!(link, target) do
    case :os.type() do
      {:win32, _} ->
        script =
          "New-Item -ItemType Junction -Path $env:CASEIN_TEST_LINK -Target $env:CASEIN_TEST_TARGET -ErrorAction Stop | Out-Null"

        case System.cmd(
               "powershell.exe",
               ["-NoProfile", "-NonInteractive", "-Command", script],
               stderr_to_stdout: true,
               env: [{"CASEIN_TEST_LINK", link}, {"CASEIN_TEST_TARGET", target}]
             ) do
          {_output, 0} -> :ok
          {output, status} -> flunk("junction creation failed (#{status}): #{output}")
        end

      _ ->
        File.ln_s!(target, link)
    end
  end
end
