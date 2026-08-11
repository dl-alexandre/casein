defmodule Casein.Agents.SkillIntegrityTest do
  use ExUnit.Case, async: true

  alias Casein.Agents.SkillIntegrity

  setup do
    root = Path.join(System.tmp_dir!(), "skill-integrity-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  describe "fingerprint/1" do
    test "identical trees fingerprint the same", %{root: root} do
      a = skill!(root, "a", "delegate", %{"SKILL.md" => "go", "references/t.md" => "tpl"})
      b = skill!(root, "b", "delegate", %{"SKILL.md" => "go", "references/t.md" => "tpl"})

      assert {:ok, hash} = SkillIntegrity.fingerprint(a)
      assert {:ok, ^hash} = SkillIntegrity.fingerprint(b)
    end

    test "a changed helper counts, not just SKILL.md", %{root: root} do
      a = skill!(root, "a", "delegate", %{"SKILL.md" => "go", "references/t.md" => "tpl"})
      b = skill!(root, "b", "delegate", %{"SKILL.md" => "go", "references/t.md" => "TPL"})

      assert {:ok, one} = SkillIntegrity.fingerprint(a)
      assert {:ok, two} = SkillIntegrity.fingerprint(b)
      refute one == two
    end

    test "moving a file is a change", %{root: root} do
      a = skill!(root, "a", "delegate", %{"SKILL.md" => "go", "references/t.md" => "tpl"})
      b = skill!(root, "b", "delegate", %{"SKILL.md" => "go", "docs/t.md" => "tpl"})

      assert {:ok, one} = SkillIntegrity.fingerprint(a)
      assert {:ok, two} = SkillIntegrity.fingerprint(b)
      refute one == two
    end

    test "the staged marker is excluded, so a staged copy still matches canonical", %{root: root} do
      # Without this exclusion every staged copy would read as divergent — the
      # same reason agent-skills.sh excludes it from its own diff -rq.
      canonical = skill!(root, "src", "delegate", %{"SKILL.md" => "go"})
      staged = skill!(root, "dst", "delegate", %{"SKILL.md" => "go", ".casein-staged" => ""})

      assert {:ok, hash} = SkillIntegrity.fingerprint(canonical)
      assert {:ok, ^hash} = SkillIntegrity.fingerprint(staged)
    end

    test "VCS and cache metadata are excluded", %{root: root} do
      a = skill!(root, "a", "delegate", %{"SKILL.md" => "go"})
      b = skill!(root, "b", "delegate", %{"SKILL.md" => "go", ".git/HEAD" => "ref: x"})

      assert {:ok, hash} = SkillIntegrity.fingerprint(a)
      assert {:ok, ^hash} = SkillIntegrity.fingerprint(b)
    end

    test "a missing directory is an error, not a hash", %{root: root} do
      assert {:error, :enoent} = SkillIntegrity.fingerprint(Path.join(root, "nope"))
    end

    test "an empty skill directory is an error rather than a shared hash", %{root: root} do
      # Two empty trees hashing equal would report agreement between two skills
      # that contain nothing.
      dir = Path.join([root, "x", "empty"])
      File.mkdir_p!(dir)

      assert {:error, :empty} = SkillIntegrity.fingerprint(dir)
    end
  end

  describe "observe/2" do
    test "one copy is single", %{root: root} do
      skill!(root, "canonical", "delegate", %{"SKILL.md" => "go"})

      assert [%{name: "delegate", state: :single, copies: [_]}] =
               SkillIntegrity.observe([root_of(root, "canonical")])
    end

    test "matching copies across roots are identical", %{root: root} do
      skill!(root, "canonical", "delegate", %{"SKILL.md" => "go"})
      skill!(root, "claude", "delegate", %{"SKILL.md" => "go", ".casein-staged" => ""})

      assert [%{name: "delegate", state: :identical, fingerprints: [_one]}] =
               SkillIntegrity.observe([root_of(root, "canonical"), root_of(root, "claude")])
    end

    test "a copy edited in place is divergent, and every path is retained", %{root: root} do
      # The gap this exists for: staging heals drift at launch, so between
      # launches an edited copy is invisible.
      skill!(root, "canonical", "delegate", %{"SKILL.md" => "go"})
      skill!(root, "claude", "delegate", %{"SKILL.md" => "go, but differently"})

      assert [%{name: "delegate", state: :divergent, copies: copies, fingerprints: prints}] =
               SkillIntegrity.observe([root_of(root, "canonical"), root_of(root, "claude")])

      assert length(prints) == 2
      assert length(copies) == 2
      # Retaining every copy path is what makes the report actionable.
      assert Enum.any?(copies, &(&1.label == "canonical"))
      assert Enum.any?(copies, &(&1.label == "claude"))
    end

    test "an unreadable copy is unknown, never merged into identical", %{root: root} do
      skill!(root, "canonical", "delegate", %{"SKILL.md" => "go"})
      unreadable = skill!(root, "claude", "delegate", %{"SKILL.md" => "go"})
      File.chmod!(Path.join(unreadable, "SKILL.md"), 0o000)
      on_exit(fn -> File.chmod(Path.join(unreadable, "SKILL.md"), 0o644) end)

      result = SkillIntegrity.observe([root_of(root, "canonical"), root_of(root, "claude")])

      # Running as root defeats chmod; only assert when the read really failed.
      case result do
        [%{state: :unknown, copies: copies}] ->
          assert Enum.any?(copies, &(&1.reason == :unreadable))

        [%{state: state}] ->
          assert state == :identical
      end
    end

    test "a root that was never staged is absence, not drift", %{root: root} do
      skill!(root, "canonical", "delegate", %{"SKILL.md" => "go"})

      assert [%{state: :single}] =
               SkillIntegrity.observe([
                 root_of(root, "canonical"),
                 %{path: Path.join(root, "never-staged"), label: "opencode"}
               ])
    end

    test "skills are reported per name, not merged across names", %{root: root} do
      skill!(root, "canonical", "delegate", %{"SKILL.md" => "a"})
      skill!(root, "canonical", "verify", %{"SKILL.md" => "b"})
      skill!(root, "claude", "delegate", %{"SKILL.md" => "DIFFERENT"})

      assert [delegate, verify] =
               SkillIntegrity.observe([root_of(root, "canonical"), root_of(root, "claude")])

      assert delegate.name == "delegate"
      assert delegate.state == :divergent
      assert verify.name == "verify"
      assert verify.state == :single
    end

    test "no roots at all yields no skills rather than an error" do
      assert SkillIntegrity.observe([]) == []
      assert SkillIntegrity.observe([%{path: "/definitely/not/here", label: "x"}]) == []
    end
  end

  describe "divergent/1" do
    test "keeps only what an operator has to act on", %{root: root} do
      skill!(root, "canonical", "same", %{"SKILL.md" => "x"})
      skill!(root, "claude", "same", %{"SKILL.md" => "x"})
      skill!(root, "canonical", "drifted", %{"SKILL.md" => "a"})
      skill!(root, "claude", "drifted", %{"SKILL.md" => "b"})

      skills = SkillIntegrity.observe([root_of(root, "canonical"), root_of(root, "claude")])

      assert Enum.map(SkillIntegrity.divergent(skills), & &1.name) == ["drifted"]
    end
  end

  ## Fixtures

  defp root_of(root, label), do: %{path: Path.join(root, label), label: label}

  defp skill!(root, root_label, name, files) do
    dir = Path.join([root, root_label, name])

    Enum.each(files, fn {rel, content} ->
      path = Path.join(dir, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end)

    dir
  end
end
