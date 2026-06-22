defmodule Mix.Tasks.Mob.Dev.Setup do
  @shortdoc "Bootstrap a safe, reproducible Mob dev connection (per-developer secrets)"

  @moduledoc """
  Generates a per-developer dev environment for connecting an IEx/distribution
  session to a Mob app running on a simulator or physical device.

  What it does (all idempotent — re-running never clobbers existing secrets):

    * Generates a **cryptographically random, per-developer cookie** and writes
      it to `.env.dev`. There is no shared or default cookie anywhere.
    * Ensures `.env.dev` is gitignored.
    * Installs `bin/dev-mobile` (the one-command dev loop).
    * Prints the security + networking model so the developer understands the
      loopback/tunnel default before exposing anything.

  ## Usage

      mix mob.dev.setup            # safe: refuses to overwrite existing files
      mix mob.dev.setup --force    # regenerate .env.dev and reinstall bin/dev-mobile

  ## Security model (read this)

  A distributed Erlang node with a known cookie is remote code execution for
  anyone who can reach EPMD + the node port. Therefore:

    * The cookie is random per developer/machine and lives only in `.env.dev`
      (gitignored). Never commit it, never share it, never default it in code.
    * Distribution binds to loopback (`127.0.0.1`) by default.
    * Physical devices should be reached over a **USB tunnel**
      (`adb forward` on Android, `iproxy` on iOS) so EPMD is never exposed on
      Wi-Fi. Direct `app@mobile.local` over Wi-Fi is intentionally NOT the
      default — it is an open RCE surface.
  """

  use Mix.Task

  @env_file ".env.dev"
  @bin_file "bin/dev-mobile"
  @gitignore ".gitignore"

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, switches: [force: :boolean], aliases: [f: :force])
    force? = Keyword.get(opts, :force, false)

    app = Mix.Project.config()[:app] || :my_app

    write_env_file(app, force?)
    ensure_gitignore()
    install_bin_script(force?)
    print_model(app)
  end

  # --- .env.dev ---------------------------------------------------------------

  defp write_env_file(app, force?) do
    cond do
      File.exists?(@env_file) and not force? ->
        Mix.shell().info([
          :yellow,
          "• #{@env_file} already exists — keeping your existing cookie. ",
          "Use --force to regenerate.",
          :reset
        ])

      true ->
        cookie = generate_cookie()
        node = "#{app}@127.0.0.1"
        File.write!(@env_file, env_template(node, cookie))
        File.chmod!(@env_file, 0o600)
        Mix.shell().info([:green, "✓ wrote #{@env_file} (random cookie, chmod 600)", :reset])
    end
  end

  # Base32 (A-Z, 2-7): safe in atoms, .env files, and shells — no /, +, or =
  # padding to trip up quoting. ~32 chars of entropy from 20 random bytes.
  defp generate_cookie do
    20
    |> :crypto.strong_rand_bytes()
    |> Base.encode32(case: :lower, padding: false)
  end

  defp env_template(node, cookie) do
    """
    # .env.dev — PER-DEVELOPER, GENERATED, NEVER COMMITTED
    #
    # Created by `mix mob.dev.setup`. Holds a random cookie unique to this
    # developer/machine. A distributed node with a known cookie is RCE, so:
    #   - No shared/default cookie. Ever.
    #   - Distribution binds to 127.0.0.1 (loopback) by default.
    #   - Physical device: use a USB tunnel (adb forward / iproxy) so EPMD is
    #     NOT reachable over Wi-Fi; your machine connects via localhost.
    #   - Simulator shares host loopback (the easy path).
    #   - mDNS / direct app@host.local over Wi-Fi is discouraged (RCE surface).

    MOB_NODE=#{node}
    MOB_COOKIE=#{cookie}

    # Optional: default device target for bin/dev-mobile ("emulator", "iphone", ...)
    # MOB_DEFAULT_DEVICE=emulator
    """
  end

  # --- .gitignore -------------------------------------------------------------

  defp ensure_gitignore do
    entry = @env_file

    cond do
      not File.exists?(@gitignore) ->
        File.write!(@gitignore, entry <> "\n")
        Mix.shell().info([:green, "✓ created #{@gitignore} ignoring #{entry}", :reset])

      gitignored?(entry) ->
        :ok

      true ->
        File.write!(@gitignore, "\n#{entry}\n", [:append])
        Mix.shell().info([:green, "✓ added #{entry} to #{@gitignore}", :reset])
    end
  end

  defp gitignored?(entry) do
    @gitignore
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.member?(entry)
  end

  # --- bin/dev-mobile ---------------------------------------------------------

  defp install_bin_script(force?) do
    cond do
      File.exists?(@bin_file) and not force? ->
        Mix.shell().info([
          :yellow,
          "• #{@bin_file} already exists — left untouched. Use --force to reinstall.",
          :reset
        ])

      true ->
        File.mkdir_p!(Path.dirname(@bin_file))
        File.write!(@bin_file, bin_script())
        File.chmod!(@bin_file, 0o755)
        Mix.shell().info([:green, "✓ installed #{@bin_file} (chmod 755)", :reset])
    end
  end

  defp bin_script do
    # Source of truth for the script lives in priv/templates/dev-mobile.sh in a
    # real package; inlined here so `mix mob.dev.setup` is self-contained.
    Mob.Dev.bin_script_template()
  end

  # --- guidance ---------------------------------------------------------------

  defp print_model(app) do
    Mix.shell().info("""

    #{IO.ANSI.bright()}Mob dev setup complete.#{IO.ANSI.reset()}

      Daily use:    bin/dev-mobile            # uses MOB_DEFAULT_DEVICE or "emulator"
                    bin/dev-mobile iphone     # explicit device

      Node:         #{app}@127.0.0.1 (loopback)
      Cookie:       random, in .env.dev (chmod 600, gitignored)

      Physical device — tunnel first so EPMD stays off the network:
        Android:    adb forward tcp:4369 tcp:4369   # EPMD
                    adb forward tcp:<port> tcp:<port>
        iOS:        iproxy 4369 4369                 # via libimobiledevice

      Reminder: iOS suspends the app in the background — the dev link drops and
      reconnects on foreground. That's a platform limit, not a bug.
    """)
  end
end
