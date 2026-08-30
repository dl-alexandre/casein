defmodule Casein.Release.AgentRuntimeScriptsTest do
  use ExUnit.Case, async: true

  alias Casein.Release.AgentRuntimeScripts

  @root Path.expand("../../..", __DIR__)

  describe "lib_closure/1 on the real checkout" do
    test "stages every helper the shipped launchers source, transitively" do
      closure = AgentRuntimeScripts.lib_closure(@root)

      # #20159: spawn-agent-worker.sh sources agent-budget.sh; the old
      # hand-maintained allowlist in mix.exs did not stage it.
      for name <- ~w(
            agent-budget.sh
            agent-identity.sh
            spawn-host-headroom.sh
            tmux-label.sh
            workspace-scoped-token.sh
            merge-agent-mcp.py
          ) do
        assert name in closure, "#{name} missing from the staged lib closure"
      end
    end

    test "every staged helper exists and every top-level script exists" do
      for name <- AgentRuntimeScripts.lib_closure(@root) do
        assert File.regular?(Path.join([@root, "scripts", "lib", name])), name
      end

      for name <- AgentRuntimeScripts.top_level() do
        assert File.regular?(Path.join([@root, "scripts", name])), name
      end
    end

    test "the closure is closed: nothing staged references an unstaged helper" do
      closure = AgentRuntimeScripts.lib_closure(@root)

      for name <- closure,
          ref <- AgentRuntimeScripts.references(Path.join([@root, "scripts", "lib", name])) do
        assert ref in closure, "#{name} references #{ref}, which is not staged"
      end
    end

    test "mix.exs stages from the closure, not a hand list" do
      mix = File.read!(Path.join(@root, "mix.exs"))
      assert mix =~ "Casein.Release.AgentRuntimeScripts.lib_closure("
      refute mix =~ ~r/lib_files = \[/
    end
  end

  describe "lib_closure/1 on a fixture tree" do
    setup do
      root =
        Path.join(System.tmp_dir!(), "agent-runtime-#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(root, "scripts/lib"))
      on_exit(fn -> File.rm_rf!(root) end)

      for name <- AgentRuntimeScripts.top_level() do
        File.write!(Path.join([root, "scripts", name]), "#!/usr/bin/env bash\n")
      end

      {:ok, root: root}
    end

    test "follows references through helpers and ignores placeholders", %{root: root} do
      File.write!(Path.join([root, "scripts", "spawn-agent-worker.sh"]), """
      #!/usr/bin/env bash
      # shellcheck source=lib/a.sh
      source "${ROOT}/scripts/lib/a.sh"
      # docs mention scripts/lib/<name> as a pattern only
      """)

      File.write!(Path.join([root, "scripts/lib/a.sh"]), ~s(source "${ROOT}/scripts/lib/b.py"\n))
      File.write!(Path.join([root, "scripts/lib/b.py"]), "# python3 scripts/lib/a.sh again\n")
      File.write!(Path.join([root, "scripts/lib/unused.sh"]), "")

      assert AgentRuntimeScripts.lib_closure(root) == ["a.sh", "b.py"]
    end

    test "a dangling reference is a broken launcher, not a skipped file", %{root: root} do
      File.write!(
        Path.join([root, "scripts", "launch-casein-agent.sh"]),
        ~s(source "${ROOT}/scripts/lib/nope.sh"\n)
      )

      assert_raise ArgumentError,
                   ~r/launch-casein-agent.sh references scripts\/lib\/nope.sh/,
                   fn ->
                     AgentRuntimeScripts.lib_closure(root)
                   end
    end
  end
end
