defmodule Scripts.CheckPortableDefaultsGuardTest do
  @moduledoc """
  Hermetic coverage of scripts/check-portable-defaults-guard.sh (#248).

  Drives the real script against the live tree and against planted temp trees —
  never mutates the checkout.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/check-portable-defaults-guard.sh", __DIR__)

  test "portable defaults guard has valid shell syntax" do
    assert {_, 0} = System.cmd("bash", ["-n", @script])
  end

  test "current tree satisfies the public-surface policy" do
    {output, status} = System.cmd("bash", [@script], stderr_to_stdout: true)

    assert status == 0, output
    assert output =~ "host-agnostic"
  end

  test "guard flags a planted /home/devbox product fallback" do
    assert_planted_fails(
      """
      defmodule Bad do
        defp home, do: System.get_env("HOME") || "/home/devbox"
      end
      """,
      "/home/devbox"
    )
  end

  test "guard flags a planted /data/workspaces/dalexandre product default" do
    assert_planted_fails(
      """
      defmodule Bad do
        @root "/data/workspaces/dalexandre/casein"
      end
      """,
      "/data/workspaces/dalexandre"
    )
  end

  test "guard flags a planted agent-worktree path product default" do
    assert_planted_fails(
      """
      defmodule Bad do
        @root "/data/casein-agent-worktrees/agent-x"
      end
      """,
      "/data/casein-agent-worktrees"
    )
  end

  test "guard flags milcgroup outside the allowlist" do
    assert_planted_fails(
      """
      defmodule Bad do
        @host "casein.devbox.milcgroup.com"
      end
      """,
      "milcgroup"
    )
  end

  test "guard flags a planted operator path in scripts/*.mjs tooling" do
    tmp = tmp_tree!()

    File.write!(Path.join(tmp, "scripts/bad-tool.mjs"), """
    import { chromium } from "/data/workspaces/dalexandre/casein/priv/scripts/node_modules/playwright/index.mjs";
    """)

    {output, status} = run_planted(tmp)
    File.rm_rf!(tmp)

    assert status == 1, output
    assert output =~ "/data/workspaces/"
    assert output =~ "operator path in shipped script tooling"
  end

  test "guard flags a planted /Users/milc product fallback in lib" do
    assert_planted_fails(
      """
      defmodule Bad do
        defp home, do: System.get_env("HOME") || "/Users/milc"
      end
      """,
      "/Users/milc"
    )
  end

  test "guard flags a planted /opt/casein/deploy-build product fallback" do
    assert_planted_fails(
      """
      defmodule Bad do
        @script "/opt/casein/deploy-build/scripts/spawn-agent-worker.sh"
      end
      """,
      "deploy-build"
    )
  end

  test "guard flags a planted hardcoded tmux -L casein in lib" do
    assert_planted_fails(
      """
      defmodule Bad do
        def args, do: ["tmux", "-L", "casein", "list-sessions"]
      end
      """,
      "tmux -L casein"
    )
  end

  test "guard flags a planted /Users/milc path in scripts tooling" do
    tmp = tmp_tree!()

    File.write!(Path.join(tmp, "scripts/bad-tool.mjs"), """
    import x from "/Users/milc/casein/priv/scripts/node_modules/x.mjs";
    """)

    {output, status} = run_planted(tmp)
    File.rm_rf!(tmp)

    assert status == 1, output
    assert output =~ "/Users/milc"
  end

  test "guard allows a clean tree with no product leaks" do
    tmp = tmp_tree!()

    File.write!(Path.join(tmp, "lib/clean.ex"), """
    defmodule Clean do
      defp home, do: System.get_env("HOME") || System.user_home!()
    end
    """)

    File.write!(Path.join(tmp, "config/config.exs"), "# clean\n")
    File.write!(Path.join(tmp, "config/runtime.exs"), "# clean — no on_devbox milcgroup\n")
    File.mkdir_p!(Path.join(tmp, "lib/casein"))
    File.write!(Path.join(tmp, "lib/casein/origin.ex"), "defmodule Casein.Origin do\nend\n")

    File.write!(Path.join(tmp, "scripts/clean-tool.mjs"), """
    import { createRequire } from "node:module";
    import path from "node:path";
    import { fileURLToPath } from "node:url";
    const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
    const require = createRequire(path.join(root, "priv/scripts/package.json"));
    const { chromium } = require("playwright");
    void chromium;
    """)

    {output, status} = run_planted(tmp)
    File.rm_rf!(tmp)

    assert status == 0, output
    assert output =~ "host-agnostic"
  end

  defp assert_planted_fails(bad_source, expect_fragment) do
    tmp = tmp_tree!()
    File.write!(Path.join(tmp, "lib/bad.ex"), bad_source)

    {output, status} = run_planted(tmp)
    File.rm_rf!(tmp)

    assert status == 1, output
    assert output =~ expect_fragment
  end

  defp tmp_tree! do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "portable-defaults-guard-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(tmp)
    File.mkdir_p!(Path.join(tmp, "lib"))
    File.mkdir_p!(Path.join(tmp, "config"))
    File.mkdir_p!(Path.join(tmp, "scripts"))
    File.mkdir_p!(Path.join(tmp, "lib/casein"))

    File.write!(Path.join(tmp, "config/config.exs"), "import_config \"runtime.exs\"\n")
    File.write!(Path.join(tmp, "config/runtime.exs"), "# clean\n")
    File.write!(Path.join(tmp, "lib/casein/origin.ex"), "defmodule Casein.Origin do\nend\n")

    script_body = File.read!(@script)
    planted = Path.join(tmp, "scripts/check-portable-defaults-guard.sh")
    File.write!(planted, script_body)
    File.chmod!(planted, 0o755)

    tmp
  end

  defp run_planted(tmp) do
    planted = Path.join(tmp, "scripts/check-portable-defaults-guard.sh")
    System.cmd("bash", [planted], cd: tmp, stderr_to_stdout: true)
  end
end
