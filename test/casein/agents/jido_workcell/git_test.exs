defmodule Casein.Agents.JidoWorkcell.GitTest do
  use ExUnit.Case, async: false

  alias Casein.Agents.JidoWorkcell.{Git, Receipt}
  alias Casein.Agents.JidoWorkcell.Git.Scope

  @other_head_sha String.duplicate("c", 40)
  @release_sha String.duplicate("b", 40)

  setup do
    recipient = self()
    previous_adapter = Application.get_env(:casein, :jido_workcell_git_adapter)
    previous_recipient = Application.get_env(:casein, :jido_workcell_git_test_recipient)

    Application.put_env(:casein, :jido_workcell_git_adapter, __MODULE__.FakeAdapter)
    Application.put_env(:casein, :jido_workcell_git_test_recipient, recipient)

    on_exit(fn ->
      restore(:jido_workcell_git_adapter, previous_adapter)
      restore(:jido_workcell_git_test_recipient, previous_recipient)
    end)

    worktree = Path.join(System.tmp_dir!(), "casein-git-#{System.unique_integer([:positive])}")
    File.mkdir_p!(worktree)

    scope = %Scope{
      repository: "dl-alexandre/casein",
      worktree_path: worktree,
      base_branch: "master",
      assigned_branch: "agent/gate0-git",
      default_branch: "master",
      workspace_id: "ws-git-test",
      owner_ref: %{provider: "github", id: "dl-alexandre", role: "operator"},
      runtime_id: "runtime-git-test",
      worker_id: "worker-git-test",
      release_sha: @release_sha,
      allowed_paths: ["README.md"],
      protected_branches: ["master", "main"],
      worktree_root: worktree,
      push_allowed?: true
    }

    on_exit(fn -> File.rm_rf!(worktree) end)
    %{scope: scope}
  end

  test "builds a waiting receipt and pushes only after receipt validation", %{scope: scope} do
    attrs = attrs("handoff-git-order")

    assert {:ok, receipt} = Git.handoff(scope, attrs)
    assert Receipt.validate(receipt) == :ok
    assert receipt.git == %{outcome: "waiting", pushed: true, merged_sha: nil}

    assert_receive {:git_adapter, :stage, ["README.md"]}
    assert_receive {:git_adapter, :commit, ["README.md"]}
    assert_receive {:git_adapter, :push, []}
  end

  test "does not push when receipt fixture validation fails", %{scope: scope} do
    attrs = Map.put(attrs("handoff-git-invalid"), :tests, [%{name: "mix test"}])

    assert {:error, :test_name_alias_not_allowed} = Git.handoff(scope, attrs)
    assert_receive {:git_adapter, :stage, ["README.md"]}
    assert_receive {:git_adapter, :commit, ["README.md"]}
    refute_receive {:git_adapter, :push}
  end

  test "replays one handoff but rejects a new expected SHA", %{scope: scope} do
    attrs = attrs("handoff-git-replay")

    assert {:ok, first} = Git.handoff(scope, attrs)
    assert {:ok, ^first} = Git.handoff(scope, attrs)

    assert {:error, :reused_handoff_new_sha} =
             Git.handoff(scope, Map.put(attrs, :head_sha, @other_head_sha))

    assert_receive {:git_adapter, :stage, ["README.md"]}
    assert_receive {:git_adapter, :commit, ["README.md"]}
    assert_receive {:git_adapter, :push, []}
    refute_receive {:git_adapter, :stage, _}
  end

  test "rejects a scope without push authority before invoking the adapter", %{scope: scope} do
    assert {:error, :push_not_authorized} =
             Git.handoff(%{scope | push_allowed?: false}, attrs("handoff-git-denied"))

    refute_receive {:git_adapter, _, _}
  end

  defp attrs(handoff_id) do
    %{
      source: "casein_worker",
      handoff_id: handoff_id,
      receipt_id: "receipt-" <> handoff_id,
      tests: [%{command: "mix test", status: "passed"}],
      paths: ["README.md"],
      message: "test audited handoff"
    }
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, value), do: Application.put_env(:casein, key, value)

  defmodule FakeAdapter do
    @behaviour Casein.Agents.JidoWorkcell.Git.Adapter

    @head_sha String.duplicate("a", 40)

    @impl true
    def bind(scope), do: {:ok, scope}

    @impl true
    def status(_scope), do: {:ok, %{}}

    @impl true
    def diff(_scope, _paths), do: {:ok, %{}}

    @impl true
    def stage(_scope, paths) do
      notify({:stage, paths})
      {:ok, %{paths: paths}}
    end

    @impl true
    def commit(_scope, attrs) do
      notify({:commit, Map.get(attrs, :paths, [])})
      {:ok, %{head_sha: @head_sha, changed_files: Map.get(attrs, :paths, [])}}
    end

    @impl true
    def push(_scope) do
      notify(:push)
      {:ok, %{pushed?: true}}
    end

    @impl true
    def head_sha(_scope), do: {:ok, @head_sha}

    defp notify({name, payload}) do
      notify(name, payload)
    end

    defp notify(name) when is_atom(name), do: notify(name, [])

    defp notify(name, payload) do
      if recipient = Application.get_env(:casein, :jido_workcell_git_test_recipient) do
        send(recipient, {:git_adapter, name, payload})
      end
    end
  end
end
