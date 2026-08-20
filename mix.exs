defmodule Casein.MixProject do
  use Mix.Project

  def project do
    [
      app: :casein,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:boundary, :phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      # Opt-in static typing pass: `mix dialyzer` (first run builds the PLT
      # under priv/plts/, which takes several minutes — not part of CI).
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
      ],
      # Ratchet, not target: suite measured 79.91% on 2026-08-03 (was 68.4% when
      # the floor was first set at 66 in 2026-06, so it had drifted ~14 points
      # behind reality and stopped ratcheting anything).
      # Raise the floor as coverage improves; never lower it.
      test_coverage: [summary: [threshold: 78]],
      releases: [
        casein: [
          include_executables_for: [:unix, :windows],
          applications: [runtime_tools: :permanent],
          steps: [
            &ensure_static_assets/1,
            &assert_no_case_colliding_modules/1,
            :assemble,
            &copy_agent_runtime_scripts/1,
            &install_operator_cli/1,
            &prune_duplicate_exec_ports/1,
            &write_release_metadata/1,
            &copy_release_docs/1
          ]
        ]
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Casein.Application, []},
      extra_applications:
        [:logger, :runtime_tools, :os_mon] ++ if(native_windows?(), do: [], else: [:erlexec])
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test, "precommit.ci": :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.7"},
      {:phoenix_ecto, "~> 4.7"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, "~> 0.22"},
      {:ecto_sqlite3, "~> 0.24.1"},
      {:phoenix_html, "~> 4.3"},
      {:phoenix_live_reload, "~> 1.6", only: :dev},
      # Files panel workspace tree auto-refresh (also a transitive dep of live_reload/credo).
      {:file_system, "~> 1.0"},
      {:phoenix_live_view, "~> 1.2"},
      {:lazy_html, ">= 0.1.0", only: :test},
      # NB: cannot be `only: :dev` — router.ex compiles the `import
      # Phoenix.LiveDashboard.Router` inside its `if compile_env(:dev_routes)`
      # block in every env (Elixir compiles both `if` branches), so the dep must
      # be present at compile time in prod too.
      {:phoenix_live_dashboard, "~> 0.9.0"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      # Pinned by immutable commit ref (not a tag) so a force-pushed tag can't
      # silently swap the vendored SVGs on `mix deps.update`. Ref == the sha
      # tag v2.2.0 pointed at. Keep the github/sparse source so the asset paths
      # (deps/heroicons/optimized) stay intact.
      {:heroicons,
       github: "tailwindlabs/heroicons",
       ref: "0435d4ca364a608cc75e2f8683d374e55abbae26",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.25"},
      {:req, "~> 0.5"},
      {:mdex, "~> 0.13.2"},
      {:mint_web_socket, "~> 1.0"},
      {:telemetry_metrics, "~> 1.1"},
      {:telemetry_poller, "~> 1.3"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.4"},
      # QR generation for mobile companion pairing (pure Elixir, no NIF).
      {:eqrcode, "~> 0.2"},
      {:dns_cluster, "~> 0.2"},
      {:bandit, "~> 1.11"},
      {:erlexec, "~> 2.3", runtime: not native_windows?()},
      {:casein_core, path: "casein_core"},
      {:casein_preview_browser, path: "casein_preview_browser"},
      ghostty_dependency(),
      {:tidewave, "~> 0.6", only: :dev},
      {:igniter, "~> 0.8", only: [:dev, :test]},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4.3", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:boundary, "~> 0.10", runtime: false},
      {:boxart, "~> 0.3", only: [:dev, :test], runtime: false},
      # #931: keep Oban. Tables were recreated (20260621140000) and
      # Casein.Signals.ObanWorker exists for the first real jobs — retention
      # sweeps for runtime_lifecycle_events, notifications, and moving
      # AttentionInbox.prune_history/1 off the insert path. Do NOT start an
      # empty poller (6813e690 already ripped that out). The first
      # `use Oban.Worker` under lib/ must also add Oban to Application
      # children; test/casein/oban_fate_test.exs enforces that pairing.
      {:oban, "~> 2.23"},
      {:hammer, "~> 7.4"},
      # Agent MCP tool actions (validated params) — standalone, no agent runtime.
      {:jido_action, "~> 2.3"},
      # CloudEvents envelope + IDs for audit causality — standalone, bus unused for now.
      {:jido_signal, "~> 2.2"},
      {:ex_machina, "~> 2.8", only: :test}
    ]
  end

  defp ghostty_dependency do
    if native_windows?() do
      {:ghostty, path: "casein_ghostty_windows", override: true}
    else
      # Patch-only. `~> 0.4` permitted a jump to 0.5.0, and pre-1.0 minors are
      # breaking by convention — on the terminal engine, unreviewed. There are
      # three copies of this project in the repo (this NIF, the vendored JS fork
      # in assets/vendor/ghostty, and casein_ghostty_windows' version literal),
      # so a bump is a coordinated change, not a routine `deps.update`.
      {:ghostty, "~> 0.5.0"}
    end
  end

  defp native_windows? do
    match?({:win32, _}, :os.type()) or System.get_env("CASEIN_NATIVE_WINDOWS") in ~w(1 true)
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind casein", "esbuild casein"],
      "assets.deploy": [
        "tailwind casein --minify",
        "esbuild casein --minify",
        "phx.digest"
      ],
      # #929: --no-audit on install is for speed/determinism. The scan is
      # scripts/npm-audit.sh (--audit-level=high). Every install path must
      # invoke that script (or `npm audit --`); check-npm-audit-guard.sh
      # fails the gate if a new install site skips it.
      "assets.npm": [
        "cmd --cd assets npm ci --no-audit --no-fund --no-progress",
        "cmd ./scripts/npm-audit.sh assets"
      ],
      "preview.npm": [
        "cmd --cd priv/scripts npm ci --omit=dev --no-audit --no-fund --no-progress",
        "cmd ./scripts/npm-audit.sh priv/scripts"
      ],
      "npm.audit": ["cmd ./scripts/npm-audit.sh"],
      "casein.release.lan": [
        "compile",
        "assets.npm",
        "preview.npm",
        "tailwind.install --if-missing",
        &resign_bun_binaries/1,
        "assets.deploy",
        "release casein --overwrite"
      ],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "deps.audit",
        # "cmd mix" spawn: hex.* tasks can be unresolvable inside an already-running
        # Mix VM on the gate runner (archive not loaded); a fresh mix invocation
        # always has them, and cmd propagates the exit code (enforcing).
        "cmd mix hex.audit",
        "sobelow --skip --exit",
        "credo --min-priority high",
        "format",
        "test"
      ],
      # CI variant: identical checks, but read-only — verifies instead of
      # mutating (format --check-formatted, deps.unlock --check-unused).
      # Ordering (#818): seconds-class static checks (format + pure shell guards)
      # run BEFORE compile so a format-only red does not burn zigler/NIF compile.
      # CASEIN_GATE_SKIP_* (via scripts/lib/gate-run-or-skip.sh) lets pr-gate's
      # fail-fast phase avoid re-running identical checks it already passed.
      "precommit.ci": [
        "cmd ./scripts/lib/gate-run-or-skip.sh FORMAT mix format --check-formatted",
        "cmd ./scripts/lib/gate-run-or-skip.sh HEEX_BOOL ./scripts/check-heex-boolean-attr-guard.sh",
        "cmd ./scripts/lib/gate-run-or-skip.sh PORTABLE ./scripts/check-portable-defaults-guard.sh",
        "cmd ./scripts/lib/gate-run-or-skip.sh NPM_AUDIT_GUARD ./scripts/check-npm-audit-guard.sh",
        "cmd ./scripts/lib/gate-run-or-skip.sh NPM_AUDIT ./scripts/npm-audit.sh",
        "compile --warnings-as-errors",
        "deps.unlock --check-unused",
        "deps.audit",
        # "cmd mix" spawn: hex.* tasks can be unresolvable inside an already-running
        # Mix VM on the gate runner (archive not loaded); a fresh mix invocation
        # always has them, and cmd propagates the exit code (enforcing).
        "cmd mix hex.audit",
        "cmd ./scripts/lib/gate-run-or-skip.sh SOBELOW mix sobelow --skip --exit",
        "cmd ./scripts/lib/gate-run-or-skip.sh CREDO mix credo --min-priority high",
        # Config-seam guard (sibling of check-scc-guard.sh). SCC stays
        # pre-push-only; this one also rides precommit.ci so PR gate and
        # deploy checks catch cycle-bound Application.get_env/3 defaults.
        # Requires a compiled tree (mix xref).
        "cmd ./scripts/check-config-seam-guard.sh",
        # Vendored Ghostty bytes must match the reviewed SHA-256 pin.
        "cmd ./scripts/check-vendor-pin-guard.sh",
        "cmd ./scripts/test-cover-gate.sh"
      ]
    ]
  end

  defp ensure_static_assets(release) do
    required_paths = [
      "priv/static/cache_manifest.json",
      "priv/static/assets/css/app.css",
      "priv/static/assets/js/app.js"
    ]

    missing = Enum.reject(required_paths, &File.exists?/1)

    if missing != [] do
      Mix.raise("""
      production release is missing static assets:

      #{Enum.map_join(missing, "\n", &"  - #{&1}")}

      Run `MIX_ENV=prod mix assets.deploy` before `mix release`, or use:

          MIX_ENV=prod mix casein.release.lan
      """)
    end

    release
  end

  # APFS/NTFS are case-insensitive: two modules whose names differ only by
  # case compile to `.beam` filenames that overwrite each other. Source-level
  # collisions are bugs, so releases reject them instead of deleting modules
  # after compilation (which previously hid a broken Boundary graph on macOS).
  defp assert_no_case_colliding_modules(release) do
    collisions =
      Mix.Project.build_path()
      |> Path.join("lib/*/ebin")
      |> Path.wildcard()
      |> Enum.flat_map(&case_colliding_beams/1)

    if collisions != [] do
      Mix.raise("""
      modules whose names differ only by case cannot ship in a release:
      their .beam files overwrite each other on case-insensitive filesystems
      (macOS APFS, Windows NTFS) and boot fails with :load_failed.

      #{Enum.map_join(collisions, "\n", &"  - #{&1}")}

      Rename one module of each pair. Compile-time-only modules are not exempt:
      their collision can still corrupt compiler plugins and local checks.
      """)
    end

    release
  end

  # Two detection modes, because the failure looks different per filesystem:
  # on case-sensitive filesystems both beams exist (duplicate downcased
  # filenames); on case-insensitive ones a single file survives whose embedded
  # module name may differ from its filename.
  defp case_colliding_beams(ebin_dir) do
    beams = Path.wildcard(Path.join(ebin_dir, "*.beam"))

    duplicates =
      beams
      |> Enum.group_by(&String.downcase(Path.basename(&1)))
      |> Enum.filter(fn {_key, files} -> length(files) > 1 end)
      |> Enum.map(fn {_key, files} ->
        "colliding filenames: #{Enum.map_join(files, ", ", &Path.basename/1)}"
      end)

    mismatches =
      Enum.flat_map(beams, fn beam ->
        expected = Path.basename(beam, ".beam")

        case :beam_lib.info(String.to_charlist(beam)) do
          info when is_list(info) ->
            actual = info |> Keyword.fetch!(:module) |> Atom.to_string()

            if actual == expected do
              []
            else
              ["#{Path.basename(beam)} contains module #{actual} (case collision)"]
            end

          _ ->
            []
        end
      end)

    duplicates ++ mismatches
  end

  # Tailwind v4's standalone CLI is a Bun-compiled binary; Darwin 27+ kills it
  # with SIGKILL (Code Signature Invalid) when the embedded __BUN segment fails
  # strict page validation. An ad-hoc re-sign after download makes it loadable.
  defp resign_bun_binaries(_args) do
    with {:unix, :darwin} <- :os.type() do
      Mix.Project.build_path()
      |> Path.dirname()
      |> Path.join("tailwind-*")
      |> Path.wildcard()
      |> Enum.each(fn bin ->
        {output, status} =
          System.cmd("codesign", ["--force", "--sign", "-", bin], stderr_to_stdout: true)

        if status != 0 do
          Mix.raise("codesign of #{bin} failed (#{status}):\n#{output}")
        end
      end)
    end

    :ok
  end

  # erlexec resolves its port binary by SUBSTRING-matching priv/*/exec-port
  # paths against :erlang.system_info(:system_architecture). When both a bare
  # arch dir (aarch64-apple-darwin) and a uname-versioned sibling
  # (aarch64-apple-darwin25.4.0) ship — deps carrying one, a local rebuild
  # adding the other — both contain the bare arch as a substring, erlexec's
  # exactly-one-match check fails, and boot dies with
  # {application_start_failure, :erlexec, ...}. Ship only the newest port.
  defp prune_duplicate_exec_ports(release) do
    ports =
      release.path
      |> Path.join("lib/erlexec-*/priv/*/exec-port")
      |> Path.wildcard()

    with [_, _ | _] <- ports do
      keep = Enum.max_by(ports, &File.stat!(&1).mtime)
      for port <- ports, port != keep, do: File.rm_rf!(Path.dirname(port))
    end

    release
  end

  defp install_operator_cli(release) do
    bin_dir = Path.join(release.path, "bin")
    generated_entrypoint = Path.join(bin_dir, "casein")
    runtime_entrypoint = Path.join(bin_dir, "casein-runtime")

    File.rename!(generated_entrypoint, runtime_entrypoint)
    File.cp!("rel/casein", generated_entrypoint)
    File.chmod!(generated_entrypoint, 0o755)
    release
  end

  defp write_release_metadata(release) do
    metadata = Casein.Release.Metadata.build_for_assemble()
    Casein.Release.Metadata.write!(release.path, metadata)
    release
  end

  defp copy_release_docs(release) do
    File.cp!("README.md", Path.join(release.path, "README.md"))
    # The source documentation contains private devbox/operator material. A
    # distributable desktop artifact must not inherit that tree implicitly.
    # End-user docs ship with the installer once its public content contract is
    # established; until then the reviewed root README is the only release doc.
    File.rm_rf!(Path.join(release.path, "docs"))
    release
  end

  # Worker launches are API calls made by the release process, so they cannot
  # assume the operator's Casein checkout (or its `scripts/` directory) is
  # present under the release root. Ship the small, checkout-independent agent
  # runtime next to the release's existing priv scripts. The scripts retain
  # their normal ROOT/scripts layout there, which also keeps product checkout
  # worktrees free of Casein infrastructure files.
  defp copy_agent_runtime_scripts(release) do
    destination =
      release.path
      |> Path.join("lib/casein-*/priv/scripts")
      |> Path.wildcard()
      |> List.first()

    destination =
      destination ||
        case release.path |> Path.join("lib/casein-*") |> Path.wildcard() do
          [app_path | _] -> Path.join(app_path, "priv/scripts")
          [] -> Mix.raise("release is missing the casein application directory")
        end

    File.mkdir_p!(destination)

    top_level = [
      "launch-casein-agent.sh",
      "spawn-agent-worker.sh",
      "materialize-agent-mcp.sh",
      "casein-curl.sh",
      "casein-agent-state.sh",
      "casein-codex-notify.sh"
    ]

    lib_files = [
      "agent-auth-profile.sh",
      "agent-env.sh",
      "agent-skills.sh",
      "agent-worktree.sh",
      "grok-capability-bundle.py",
      "grok-leader-runtime.py",
      "grok-managed-home.py",
      "grok-sandbox-profile.py",
      "merge-agent-mcp.py",
      "real-agent-bin.sh",
      "repair-tmux-env.sh",
      "sidechat.sh",
      "spawn-host-headroom.sh",
      "tmux-label.sh",
      "workspace-scoped-token.sh"
    ]

    Enum.each(top_level, fn name ->
      source = Path.join([__DIR__, "scripts", name])
      target = Path.join(destination, name)
      File.mkdir_p!(Path.dirname(target))
      File.cp!(source, target)
      if String.ends_with?(name, ".sh"), do: File.chmod!(target, 0o755)
    end)

    lib_destination = Path.join(destination, "lib")
    File.mkdir_p!(lib_destination)

    Enum.each(lib_files, fn name ->
      source = Path.join([__DIR__, "scripts", "lib", name])
      target = Path.join(lib_destination, name)
      File.mkdir_p!(Path.dirname(target))
      File.cp!(source, target)
      if String.ends_with?(name, ".sh"), do: File.chmod!(target, 0o755)
    end)

    hooks_source = Path.join([__DIR__, "scripts", "agent-hooks"])
    File.cp_r!(hooks_source, Path.join(destination, "agent-hooks"))
    release
  end
end
