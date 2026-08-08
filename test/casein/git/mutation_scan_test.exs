defmodule Casein.Git.MutationScanTest do
  use ExUnit.Case, async: true

  alias Casein.Git.MutationScan

  describe "commands that write the tree" do
    test "the subcommands that touch the index or working copy" do
      for subcommand <- ~w(add am apply checkout cherry-pick clean commit merge mv
                           pull rebase reset restore revert rm stash switch) do
        assert {:mutation, %{subcommand: ^subcommand}} = MutationScan.scan("git #{subcommand}"),
               "expected `git #{subcommand}` to read as a tree write"
      end
    end

    test "finds the write after a cd, in a chain" do
      assert {:mutation, %{subcommand: "reset", command: "git reset --hard origin/master"}} =
               MutationScan.scan("cd /data/wt && git reset --hard origin/master")
    end

    test "finds it past a leading env assignment or wrapper" do
      assert {:mutation, %{subcommand: "commit"}} =
               MutationScan.scan("GIT_AUTHOR_NAME=x git commit -m 'y'")

      assert {:mutation, %{subcommand: "commit"}} =
               MutationScan.scan("env GIT_AUTHOR_NAME=x git commit -m 'y'")
    end

    test "an absolute git path still reads as git" do
      assert {:mutation, %{subcommand: "clean"}} = MutationScan.scan("/usr/bin/git clean -fd")
    end

    test "git flags before the subcommand do not hide it" do
      assert {:mutation, %{subcommand: "commit"}} =
               MutationScan.scan("git --no-pager -c user.name=x commit -m y")
    end
  end

  describe "commands that do not" do
    test "reads pass" do
      for command <- [
            "git status",
            "git log --oneline -5",
            "git diff HEAD",
            "git show abc123",
            "git rev-parse --show-toplevel",
            "git worktree list",
            "git config user.name"
          ] do
        assert MutationScan.scan(command) == :none, "expected `#{command}` to pass"
      end
    end

    # These are consequential but they move refs, not the tree two panes are
    # fighting over — and agents push constantly, so blocking them would make the
    # guard something people turn off.
    test "push and fetch move refs, not the working tree" do
      assert MutationScan.scan("git push -u origin HEAD") == :none
      assert MutationScan.scan("git fetch origin --quiet") == :none
    end

    test "listing branches passes; deleting or moving one does not" do
      assert MutationScan.scan("git branch") == :none
      assert MutationScan.scan("git branch --list 'agent/*'") == :none
      assert {:mutation, %{subcommand: "branch"}} = MutationScan.scan("git branch -D old-thing")
      assert {:mutation, %{subcommand: "branch"}} = MutationScan.scan("git branch -m a b")
    end

    # The first token of each segment is what decides, so a git command quoted
    # inside another program's arguments is that program's business.
    test "a git command inside a quoted argument is not a git command" do
      assert MutationScan.scan(~s(echo "git reset --hard")) == :none
      assert MutationScan.scan(~s(grep -r 'git commit' scripts/)) == :none
    end

    test "non-git commands and junk pass" do
      assert MutationScan.scan("mix test") == :none
      assert MutationScan.scan("") == :none
      assert MutationScan.scan("Enter") == :none
      assert MutationScan.scan(nil) == :none
    end
  end

  # `git -C` is the difference between "writes this pane's tree" and "writes some
  # other tree". The repo's own scripts use it constantly, so a guard that could
  # not see it would refuse the wrong calls.
  describe "which tree the write lands in" do
    test "no redirection means the pane's own tree" do
      assert {:mutation, %{dir: nil}} = MutationScan.scan("git commit -m x")
    end

    test "-C names the tree that is written" do
      assert {:mutation, %{dir: "/data/other", subcommand: "commit"}} =
               MutationScan.scan("git -C /data/other commit -m x")
    end

    test "--work-tree names it too, in both spellings" do
      assert {:mutation, %{dir: "/data/other"}} =
               MutationScan.scan("git --work-tree /data/other checkout .")

      assert {:mutation, %{dir: "/data/other"}} =
               MutationScan.scan("git --work-tree=/data/other checkout .")
    end

    test "-c config is not -C directory" do
      assert {:mutation, %{dir: nil, subcommand: "commit"}} =
               MutationScan.scan("git -c core.hooksPath=/dev/null commit -m x")
    end
  end

  test "mutation?/1 is the boolean form" do
    assert MutationScan.mutation?("git reset --hard")
    refute MutationScan.mutation?("git status")
  end
end
