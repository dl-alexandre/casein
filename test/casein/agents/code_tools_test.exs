defmodule Casein.Agents.CodeToolsTest do
  use Casein.TestCase, async: false

  alias Casein.Agents.Activity
  alias Casein.Agents.CodeTools
  alias Casein.Runtimes
  alias Casein.Workspace
  alias Casein.Workspaces.State
  alias Casein.Workspaces.State.MemoryAdapter

  @workspace_id "ws-code-tools"

  setup do
    prev_state = Application.get_env(:casein, :workspace_state_adapter)
    prev_runtimes = Application.get_env(:casein, :runtimes_adapter)

    base = Path.join(System.tmp_dir!(), "code-tools-#{System.unique_integer([:positive])}")
    repo = Path.join(base, "repo")

    Application.put_env(:casein, :workspace_state_adapter, MemoryAdapter)
    Application.put_env(:casein, :runtimes_adapter, Casein.Runtimes.MemoryAdapter)

    MemoryAdapter.clear()
    Runtimes.clear()
    Activity.clear()
    init_repo!(repo)
    seed_workspace!(@workspace_id, "code-tools", repo)

    on_exit(fn ->
      MemoryAdapter.clear()
      Runtimes.clear()
      Activity.clear()
      File.rm_rf!(base)
      restore(:workspace_state_adapter, prev_state)
      restore(:runtimes_adapter, prev_runtimes)
    end)

    %{repo: repo, base: base}
  end

  test "code_read returns a bounded file range", %{repo: repo} do
    File.write!(Path.join(repo, "lib/hello.ex"), "a\nb\nc\nd\n")

    assert {:ok, result} =
             CodeTools.invoke(
               "code_read",
               %{
                 "workspace_id" => @workspace_id,
                 "worktree_path" => repo,
                 "path" => "lib/hello.ex",
                 "start_line" => 2,
                 "end_line" => 3
               },
               %{actor: "ws:#{@workspace_id}"}
             )

    assert result.content == "b\nc"
    assert result.start_line == 2
    assert result.end_line == 3
    assert result.truncated
    assert result.range_truncated
    refute result.byte_truncated
  end

  test "code_read rejects absolute, traversal, backslash, NUL, and .git paths", %{repo: repo} do
    ctx = %{actor: "ws:#{@workspace_id}"}

    for path <- ["/etc/passwd", "../escape", "lib\\secret", "lib/" <> <<0>> <> "x", ".git/config"] do
      assert {:error, %{error: reason}} =
               CodeTools.invoke(
                 "code_read",
                 %{
                   "workspace_id" => @workspace_id,
                   "worktree_path" => repo,
                   "path" => path
                 },
                 ctx
               )

      assert reason in [
               :absolute_path,
               :outside_root,
               :backslash_in_path,
               :nul_in_path,
               :path_not_allowed
             ]
    end
  end

  test "code_read rejects a worktree from another location", %{repo: repo, base: base} do
    other = Path.join(base, "other")
    File.mkdir_p!(other)

    assert {:error, %{error: :worktree_not_assigned}} =
             CodeTools.invoke(
               "code_read",
               %{
                 "workspace_id" => @workspace_id,
                 "worktree_path" => other,
                 "path" => "README.md"
               },
               %{actor: "ws:#{@workspace_id}"}
             )

    _ = repo
  end

  test "code_read rejects a nested directory that is not an assigned worktree", %{repo: repo} do
    nested = Path.join(repo, "nested")
    File.mkdir_p!(nested)

    assert {:error, %{error: :worktree_not_assigned}} =
             CodeTools.invoke(
               "code_read",
               %{
                 "workspace_id" => @workspace_id,
                 "worktree_path" => nested,
                 "path" => "README.md"
               },
               %{actor: "ws:#{@workspace_id}"}
             )
  end

  test "code_search returns capped matches", %{repo: repo} do
    File.write!(Path.join(repo, "lib/a.ex"), "needle one\n")
    File.write!(Path.join(repo, "lib/b.ex"), "needle two\n")

    assert {:ok, result} =
             CodeTools.invoke(
               "code_search",
               %{
                 "workspace_id" => @workspace_id,
                 "worktree_path" => repo,
                 "query" => "needle",
                 "max_matches" => 1
               },
               %{actor: "ws:#{@workspace_id}"}
             )

    assert result.match_count == 1
    assert result.truncated
    assert hd(result.matches).text =~ "needle"
  end

  test "code_apply_patch applies a validated diff and is idempotent on retry", %{repo: repo} do
    File.write!(Path.join(repo, "note.txt"), "hello\n")
    git!(repo, ["add", "note.txt"])
    git!(repo, ["commit", "-m", "add note"])
    File.write!(Path.join(repo, "note.txt"), "hello world\n")
    patch = git_diff!(repo, "note.txt")
    File.write!(Path.join(repo, "note.txt"), "hello\n")

    args = %{
      "workspace_id" => @workspace_id,
      "worktree_path" => repo,
      "patch" => patch,
      "idempotency_key" => "retry-1"
    }

    assert {:ok, first} =
             CodeTools.invoke("code_apply_patch", args, %{actor: "ws:#{@workspace_id}"})

    assert first.applied
    refute first.already_applied
    assert File.read!(Path.join(repo, "note.txt")) == "hello world\n"

    assert {:ok, second} =
             CodeTools.invoke("code_apply_patch", args, %{actor: "ws:#{@workspace_id}"})

    assert second.applied
    assert second.already_applied
    assert second.idempotent
  end

  test "code_apply_patch rejects a traversal header", %{repo: repo} do
    patch = """
    --- a/../secret
    +++ b/../secret
    @@ -1 +1 @@
    -a
    +b
    """

    assert {:error, %{error: reason}} =
             CodeTools.invoke(
               "code_apply_patch",
               %{
                 "workspace_id" => @workspace_id,
                 "worktree_path" => repo,
                 "patch" => patch
               },
               %{actor: "ws:#{@workspace_id}"}
             )

    assert reason in [:invalid_path, :outside_root]
  end

  test "code_exec refuses raw shell and unknown command ids", %{repo: repo} do
    assert {:error, %{error: :not_allowed}} =
             CodeTools.invoke(
               "code_exec",
               %{
                 "workspace_id" => @workspace_id,
                 "worktree_path" => repo,
                 "command_id" => "rm -rf /"
               },
               %{actor: "ws:#{@workspace_id}"}
             )
  end

  test "code_exec refuses extra_args with shell metacharacters", %{repo: repo} do
    assert {:error, %{error: :invalid_argument}} =
             CodeTools.invoke(
               "code_exec",
               %{
                 "workspace_id" => @workspace_id,
                 "worktree_path" => repo,
                 "command_id" => "test",
                 "extra_args" => ["foo; reboot"]
               },
               %{actor: "ws:#{@workspace_id}"}
             )
  end

  test "code_exec runs an allowlisted verifier and reports timeout/truncation fields", %{
    repo: repo
  } do
    assert {:ok, result} =
             CodeTools.invoke(
               "code_exec",
               %{
                 "workspace_id" => @workspace_id,
                 "worktree_path" => repo,
                 "command_id" => "format",
                 "timeout_ms" => 1,
                 "max_output_bytes" => 32
               },
               %{actor: "ws:#{@workspace_id}"}
             )

    assert result.command_id == "format"
    assert result.argv == ["mix", "format", "--check-formatted"]
    assert is_boolean(result.timed_out)
    assert is_boolean(result.output_truncated)
    assert is_boolean(result.cancelled)
    assert result.status in ["completed", "timeout", "error"]
  end

  test "code_exec reports a non-zero verifier exit as failed", %{repo: repo} do
    assert {:ok, result} =
             CodeTools.invoke(
               "code_exec",
               %{
                 "workspace_id" => @workspace_id,
                 "worktree_path" => repo,
                 "command_id" => "test",
                 "extra_args" => ["missing_test_file.exs"]
               },
               %{actor: "ws:#{@workspace_id}"}
             )

    assert result.exit_code != 0
    assert result.status == "failed"
  end

  test "code_search keeps the encoded match payload within max_bytes", %{repo: repo} do
    File.write!(
      Path.join(repo, "lib/many.ex"),
      Enum.map_join(1..50, "\n", &"needle #{&1} with a deliberately long line")
    )

    assert {:ok, result} =
             CodeTools.invoke(
               "code_search",
               %{
                 "workspace_id" => @workspace_id,
                 "worktree_path" => repo,
                 "query" => "needle",
                 "max_matches" => 50,
                 "max_bytes" => 256
               },
               %{actor: "ws:#{@workspace_id}"}
             )

    assert result.byte_truncated
    assert byte_size(Jason.encode!(result.matches)) <= 256
  end

  test "code_exec denies when the actor is unauthenticated", %{repo: repo} do
    assert {:error, %{error: :policy_denied, reason: :forbidden}} =
             CodeTools.invoke(
               "code_exec",
               %{
                 "workspace_id" => @workspace_id,
                 "worktree_path" => repo,
                 "command_id" => "format"
               },
               %{actor: nil}
             )
  end

  test "missing workspace is a structured error", %{repo: repo} do
    assert {:error, %{error: :workspace_not_found}} =
             CodeTools.invoke(
               "code_read",
               %{
                 "workspace_id" => "ws-missing",
                 "worktree_path" => repo,
                 "path" => "README.md"
               },
               %{actor: "ws:missing"}
             )
  end

  defp seed_workspace!(id, name, repo) do
    {:ok, _record} =
      State.sync(%Workspace{
        id: id,
        name: name,
        path: repo,
        status: :running,
        metadata: %{"id" => id, "name" => name}
      })
  end

  defp init_repo!(repo) do
    File.mkdir_p!(Path.join(repo, "lib"))
    git!(repo, ["init"])
    git!(repo, ["config", "user.name", "Casein Test"])
    git!(repo, ["config", "user.email", "casein-test@localhost"])
    File.write!(Path.join(repo, "README.md"), "# Code tools\n")
    git!(repo, ["add", "README.md"])
    git!(repo, ["commit", "-m", "Initial commit"])
  end

  defp git_diff!(cwd, path) do
    case System.cmd("git", ["-C", cwd, "diff", "--", path], stderr_to_stdout: true) do
      {output, code} when code in [0, 1] and output != "" -> output
      {output, code} -> flunk("git diff failed with #{code}: #{output}")
    end
  end

  defp git!(cwd, args) do
    case System.cmd("git", ["-C", cwd | args], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, code} -> flunk("git #{Enum.join(args, " ")} failed with #{code}: #{output}")
    end
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, value), do: Application.put_env(:casein, key, value)
end
