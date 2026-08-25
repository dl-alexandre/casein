defmodule Casein.Agents.JidoSkillsTest do
  use Casein.TestCase, async: false

  alias Casein.Agents.{Activity, JidoPod, JidoSkills}
  alias Casein.Runtimes
  alias Casein.Workspace
  alias Casein.Workspaces.State
  alias Casein.Workspaces.State.MemoryAdapter

  @workspace_id "ws-jido-skills"

  setup do
    previous = %{
      flag: Application.get_env(:casein, :jido_headless),
      workspaces: Application.get_env(:casein, :jido_headless_workspaces),
      model: Application.get_env(:casein, :jido_default_model),
      runner: Application.get_env(:casein, :jido_code_actions),
      code: Application.get_env(:casein, :jido_actions_code_invoke),
      state: Application.get_env(:casein, :workspace_state_adapter),
      runtimes: Application.get_env(:casein, :runtimes_adapter)
    }

    base = Path.join(System.tmp_dir!(), "jido-skills-#{System.unique_integer([:positive])}")
    repo = Path.join(base, "repo")
    extra = Path.join(base, "skills")

    Application.put_env(:casein, :jido_headless, true)
    Application.put_env(:casein, :jido_headless_workspaces, %{})
    Application.put_env(:casein, :workspace_state_adapter, MemoryAdapter)
    Application.put_env(:casein, :runtimes_adapter, Casein.Runtimes.MemoryAdapter)

    MemoryAdapter.clear()
    Runtimes.clear()
    Activity.clear()
    init_repo!(repo)
    seed_workspace!(@workspace_id, "jido-skills", repo)

    on_exit(fn ->
      _ = JidoPod.stop_pod(@workspace_id)

      Registry.select(Casein.Agents.JidoPod.Registry, [
        {{{:pod, :"$1"}, :_, :_}, [], [:"$1"]}
      ])
      |> Enum.each(&JidoPod.stop_pod/1)

      MemoryAdapter.clear()
      Runtimes.clear()
      Activity.clear()
      File.rm_rf!(base)
      restore(:jido_headless, previous.flag)
      restore(:jido_headless_workspaces, previous.workspaces)
      restore(:jido_default_model, previous.model)
      restore(:jido_code_actions, previous.runner)
      restore(:jido_actions_code_invoke, previous.code)
      restore(:workspace_state_adapter, previous.state)
      restore(:runtimes_adapter, previous.runtimes)
    end)

    %{repo: repo, extra: extra, roots: [packaged()]}
  end

  test "loads packaged task skills and separates them from TUI instructions", %{
    roots: roots,
    extra: extra
  } do
    {:ok, skills} = JidoSkills.load(roots)
    names = Enum.map(skills, & &1.name)

    assert "inspect" in names
    assert "representative-edit" in names
    assert Enum.all?(JidoSkills.default_coding(), &(&1 in names))

    {:ok, inspect} = JidoSkills.get("inspect", roots)
    assert inspect.kind == :task
    assert inspect.actions == ["code_read", "code_search"]
    assert JidoSkills.support(inspect).supported?

    runtime =
      write_skill!(
        extra,
        "delegate-to-worker",
        """
        ---
        name: delegate-to-worker
        kind: runtime
        description: Spawn a TUI worker through terminal MCP.
        ---

        Call terminal_send_command after worker_launch.
        """
      )

    {:ok, loaded} = JidoSkills.parse(runtime)
    assert loaded.kind == :runtime
    refute JidoSkills.support(loaded).supported?
    assert JidoSkills.support(loaded).reason == :runtime_specific
  end

  test "maps skills onto the typed action catalog and fails unsupported ones", %{
    roots: roots,
    extra: extra
  } do
    {:ok, inspect} = JidoSkills.get("inspect", roots)
    assert JidoSkills.support(inspect).actions == ["code_read", "code_search"]

    {:ok, patch} = JidoSkills.get("patch", roots)
    assert JidoSkills.support(patch).supported?

    {:ok, git} = JidoSkills.get("git-inspect", roots)
    support = JidoSkills.support(git)
    refute support.supported?
    assert support.reason == :not_yet_supported
    assert "git_status" in support.missing

    write_skill!(extra, "keystroke", """
    ---
    name: keystroke
    kind: task
    actions:
      - terminal_send_keys
    ---
    """)

    {:ok, keystroke} = JidoSkills.get("keystroke", [extra])
    key_support = JidoSkills.support(keystroke)
    refute key_support.supported?
    assert key_support.reason == :runtime_specific
    assert "terminal_send_keys" in key_support.forbidden
  end

  test "selector chooses jido, opencode, or explicit fallback without a pane", %{roots: roots} do
    assert {:ok, %{runtime: :jido, pane_required?: false, headless: true}} =
             JidoSkills.select(@workspace_id, skill: "inspect", roots: roots)

    assert {:ok, %{runtime: :opencode, reason: :explicit_opencode, pane_required?: false}} =
             JidoSkills.select(@workspace_id, runtime: :opencode, skill: "inspect", roots: roots)

    Application.put_env(:casein, :jido_headless, false)

    assert {:ok, %{runtime: :opencode, reason: :legacy_opencode}} =
             JidoSkills.select(@workspace_id, roots: roots)

    assert {:error, %{error: :jido_disabled, retryable: false}} =
             JidoSkills.select(@workspace_id, runtime: :jido, skill: "inspect", roots: roots)

    Application.put_env(:casein, :jido_headless, true)

    assert {:error, %{error: :not_yet_supported, skill: "git-inspect", retryable: false}} =
             JidoSkills.select(@workspace_id, skill: "git-inspect", roots: roots)

    assert {:ok, %{shadow?: true, canary?: false}} =
             JidoSkills.select(@workspace_id, skill: "inspect", mode: :shadow, roots: roots)
  end

  test "provider failure falls back to OpenCode without duplicating a mutation" do
    prior = %{
      workspace_id: @workspace_id,
      attempt_id: "att-fallback",
      next_index: 1,
      completed: [
        %{name: "code_apply_patch", mutation_token: "mut-1"},
        %{name: "code_read"}
      ]
    }

    receipt = JidoSkills.fallback(prior, :provider_unavailable)
    assert receipt.runtime == :opencode
    assert receipt.fallback?
    assert receipt.reason == :provider_unavailable
    assert receipt.completed_mutation_tokens == ["mut-1"]
    assert receipt.applied? == false
    assert receipt.pane_required? == false

    remaining =
      JidoSkills.remaining_actions(receipt, [
        %{name: "code_apply_patch", mutation_token: "mut-1"},
        %{name: "code_exec", mutation_token: "mut-2"}
      ])

    assert Enum.map(remaining, & &1.name) == ["code_exec"]

    entries = Activity.recent(@workspace_id, 10)
    assert Enum.any?(entries, &(&1.source == :jido_skills and &1.tool == "jido_fallback"))
    refute Enum.any?(entries, &match?(%{metadata: %{pane_id: pane}} when is_binary(pane), &1))
  end

  test "same fixture on both backends compares outcome, paths, verification, and identity", %{
    repo: repo,
    roots: roots
  } do
    File.write!(Path.join(repo, "lib/hello.ex"), "needle one\n")
    git!(repo, ["add", "lib/hello.ex"])
    git!(repo, ["commit", "-m", "add hello"])
    File.write!(Path.join(repo, "lib/hello.ex"), "needle two\n")
    patch = git_diff!(repo, "lib/hello.ex")
    File.write!(Path.join(repo, "lib/hello.ex"), "needle one\n")

    opts = %{
      workspace_id: @workspace_id,
      worktree_path: repo,
      roots: roots,
      path: "lib/hello.ex",
      query: "needle",
      patch: patch,
      actor: "ws:#{@workspace_id}"
    }

    assert {:ok, jido} = JidoSkills.run_fixture(:jido, Map.put(opts, :attempt_id, "att-jido"))
    File.write!(Path.join(repo, "lib/hello.ex"), "needle one\n")

    assert {:ok, opencode} =
             JidoSkills.run_fixture(:opencode, Map.put(opts, :attempt_id, "att-opencode"))

    assert jido.outcome == :ok
    assert opencode.outcome == :ok
    assert jido.changed_paths == opencode.changed_paths
    assert "lib/hello.ex" in jido.changed_paths
    assert jido.verification == opencode.verification
    assert jido.audit_identity.workspace_id == opencode.audit_identity.workspace_id
    assert jido.audit_identity.task_id == opencode.audit_identity.task_id
    assert jido.audit_identity.backend == :jido
    assert opencode.audit_identity.backend == :opencode
    assert jido.headless and is_nil(jido.pane_id)
    assert opencode.headless and is_nil(opencode.pane_id)
    assert File.read!(Path.join(repo, "lib/hello.ex")) == "needle two\n"
  end

  test "evidence is stale after the skill or catalog contract changes", %{extra: extra} do
    path =
      write_skill!(extra, "inspect", """
      ---
      name: inspect
      kind: task
      actions:
        - code_read
      ---
      v1
      """)

    {:ok, skill} = JidoSkills.parse(path)

    binding =
      JidoSkills.bind_attempt(%{
        workspace_id: @workspace_id,
        attempt_id: "att-ev",
        backend: :jido,
        skill: skill
      })

    assert binding.pane_id == nil
    assert binding.headless
    assert JidoSkills.evidence_status(binding) == :current

    stale = %{binding | catalog_digest: "not-the-catalog"}
    assert JidoSkills.evidence_status(stale) == :stale

    File.write!(path, """
    ---
    name: inspect
    kind: task
    actions:
      - code_read
    ---
    v2
    """)

    {:ok, updated} = JidoSkills.parse(path)
    assert updated.version != skill.version
    assert JidoSkills.evidence_status(binding) == :stale
  end

  test "parity matrix names first-release gaps instead of approximating them" do
    matrix = JidoSkills.parity_matrix()
    by = Map.new(matrix, &{&1.capability, &1})

    assert by.inspect.first_release == :supported
    assert by.patch.first_release == :supported
    assert by.verify.first_release == :supported
    assert by.git.first_release == :not_yet_supported
    assert by.task_control.first_release == :not_yet_supported
    assert by.tui_runtime.first_release == :runtime_specific
    assert by.human_input.jido == :supported
    assert by.progress_evidence.jido == :supported
    assert by.provider_unavailable.jido == :supported
    assert by.cancel_retry_resume.jido == :supported
  end

  defp packaged, do: Path.join(File.cwd!(), "priv/jido/skills")

  defp write_skill!(root, name, body) do
    dir = Path.join(root, name)
    File.mkdir_p!(dir)
    path = Path.join(dir, "SKILL.md")
    File.write!(path, body)
    path
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
    File.write!(Path.join(repo, "README.md"), "# Jido skills\n")
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
