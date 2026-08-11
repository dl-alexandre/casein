defmodule Casein.Terminals.Shims do
  @moduledoc """
  Materializes Casein terminal command shims and exposes terminal capability env.

  The shims are intentionally scoped to Casein terminal panes by prepending this
  directory to pane `PATH`; the host's real binaries stay untouched and can be
  invoked directly by absolute path when debugging.
  """

  @default_dir "~/.casein/terminal-shims"
  @default_tool_root "~/.casein/tools"
  @default_path "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  @shell_integration_name "shell-integration.bash"
  @zsh_integration_name "shell-integration.zsh"
  @zdotdir_name "zdotdir"
  # Panes follow the user's login shell: when $SHELL is zsh (the macOS default)
  # and the staged ZDOTDIR bootstrap is materialized, enter integrated zsh;
  # otherwise fall through to the original integrated-bash chain (the devbox
  # default, where $SHELL is bash or unset under systemd).
  @shell_command_body ~s(__casein_shell="${SHELL:-}"; if [ -n "$__casein_shell" ] && [ -x "$__casein_shell" ] && [ "${__casein_shell##*/}" = zsh ] && [ -r "${CASEIN_SHELL_INTEGRATION_ZDOTDIR:-}/.zshrc" ]; then CASEIN_USER_ZDOTDIR="${ZDOTDIR:-${HOME:-}}" ZDOTDIR="${CASEIN_SHELL_INTEGRATION_ZDOTDIR}" unset CASEIN_SHELL_INTEGRATION_LOADED; export CASEIN_USER_ZDOTDIR ZDOTDIR; exec "$__casein_shell" -il; fi; if [ -r "${CASEIN_SHELL_INTEGRATION_BASH:-}" ] && command -v bash >/dev/null 2>&1; then exec bash --init-file "$CASEIN_SHELL_INTEGRATION_BASH" -i; fi; if command -v bash >/dev/null 2>&1; then exec bash -l; fi; if [ -n "$__casein_shell" ] && [ -x "$__casein_shell" ]; then exec "$__casein_shell"; fi; exec sh)
  @capability_env %{
    "CASEIN_TERMINAL" => "1",
    "CASEIN_CLIPBOARD" => "osc52",
    "CASEIN_SHELL_INTEGRATION" => "1",
    "COLORTERM" => "truecolor"
  }
  @registry %{
    "casein-open" => %{
      env: %{},
      requires: ["api"],
      script: :casein_open,
      notes: "Open files and localhost URLs in the connected Casein viewer."
    },
    "elio" => %{
      env: %{"ELIO_CLIPBOARD_OSC52" => "1"},
      install: %{method: :cargo, package: "elio", bin: "elio"},
      requires: ["osc52"],
      notes: "Use browser clipboard through Casein's OSC52 bridge.",
      theme: %{
        mode: :static,
        path: "~/.config/elio/theme.toml",
        template: "tool_themes/elio/theme.toml"
      }
    },
    # grok is an agent launcher shimmed into ~/.casein/agent-shims by
    # install-agent-shims.sh. The terminal-shims dir is FIRST on
    # path_with_shims/1, so a materialized grok shim here would shadow that
    # launcher — this entry must stay `shim: false` and exists only so
    # ToolThemes can stamp grok's scheme-variant theme.
    "grok" => %{
      shim: false,
      env: %{},
      requires: [],
      notes: "Theme-only entry; the launcher shim is owned by install-agent-shims.sh.",
      theme: %{
        mode: :scheme_variant,
        path: "~/.grok/config.toml",
        stamp: %{
          format: :toml,
          section: "ui",
          key: "theme",
          # ~/.grok/config.toml is one file shared by every workspace and
          # viewer on the box, and grok hot-reloads it — the stamp restyles
          # every running grok pane, not just the caller's. grokday is banned
          # outright: it renders illegibly in the Casein viewer (operator
          # call, 2026-07-07). Both values here must stay legible on either
          # scheme so a mixed-scheme clobber is cosmetic, never unreadable.
          values: %{dark: "groknight", light: "tokyonight"}
        }
      }
    }
  }

  @type install_spec :: %{
          method: :cargo,
          package: String.t(),
          bin: String.t()
        }

  @type static_theme_spec :: %{
          mode: :static,
          path: String.t(),
          template: String.t()
        }

  @type scheme_variant_theme_spec :: %{
          mode: :scheme_variant,
          path: String.t(),
          stamp: %{
            format: :toml,
            section: String.t(),
            key: String.t(),
            values: %{dark: String.t(), light: String.t()}
          }
        }

  @type theme_spec :: static_theme_spec() | scheme_variant_theme_spec()

  @type shim_spec :: %{
          optional(:install) => install_spec(),
          optional(:shim) => boolean(),
          optional(:theme) => theme_spec(),
          optional(:script) => :casein_open,
          env: %{String.t() => String.t()},
          requires: [String.t()],
          notes: String.t() | nil
        }

  @doc "Known terminal shims keyed by command name."
  @spec registry() :: %{String.t() => shim_spec()}
  def registry, do: @registry

  @doc "Tool theme descriptors keyed by command name, for ToolThemes provisioning."
  @spec theme_specs() :: %{String.t() => theme_spec()}
  def theme_specs do
    for {name, %{theme: theme}} <- @registry, into: %{}, do: {name, theme}
  end

  @doc "Directory where Casein materializes terminal shims."
  @spec dir() :: String.t()
  def dir do
    :casein
    |> Application.get_env(:terminal_shims_dir)
    |> non_empty_or(System.get_env("CASEIN_TERMINAL_SHIMS_DIR"))
    |> non_empty_or(@default_dir)
    |> Path.expand()
  end

  @doc "Directory where Casein installs self-healed terminal tools."
  @spec tool_root() :: String.t()
  def tool_root do
    :casein
    |> Application.get_env(:terminal_tools_dir)
    |> non_empty_or(System.get_env("CASEIN_TERMINAL_TOOLS_DIR"))
    |> non_empty_or(@default_tool_root)
    |> Path.expand()
  end

  @doc "Directory that contains Casein-managed terminal tool binaries."
  @spec tools_bin_dir() :: String.t()
  def tools_bin_dir, do: Path.join(tool_root(), "bin")

  @doc "Absolute path to a materialized shim."
  @spec shim_path(String.t()) :: String.t()
  def shim_path(name) when is_binary(name), do: Path.join(dir(), name)

  @doc "Absolute path to Casein's bash shell integration file."
  @spec shell_integration_path() :: String.t()
  def shell_integration_path, do: Path.join(dir(), @shell_integration_name)

  @doc "Absolute path to Casein's zsh shell integration file."
  @spec zsh_integration_path() :: String.t()
  def zsh_integration_path, do: Path.join(dir(), @zsh_integration_name)

  @doc """
  Absolute path to the staged ZDOTDIR that bootstraps integrated zsh panes.

  zsh has no `--init-file`; the staged wrapper dotfiles chain to the user's
  real `~/.zshenv`/`~/.zprofile`/`~/.zshrc`, restore the original `ZDOTDIR`,
  then load the zsh shell integration last.
  """
  @spec zdotdir_path() :: String.t()
  def zdotdir_path, do: Path.join(dir(), @zdotdir_name)

  @doc "Absolute path to a materialized installer backend for a shimmed tool."
  @spec install_script_path(String.t()) :: String.t()
  def install_script_path(name) when is_binary(name), do: Path.join([dir(), "install", name])

  @doc "Generic terminal capability variables safe for every Casein pane."
  @spec capability_env() :: %{String.t() => String.t()}
  def capability_env do
    @capability_env
    |> Map.put("CASEIN_SHELL_INTEGRATION_BASH", shell_integration_path())
    |> Map.put("CASEIN_SHELL_INTEGRATION_ZSH", zsh_integration_path())
    |> Map.put("CASEIN_SHELL_INTEGRATION_ZDOTDIR", zdotdir_path())
  end

  @doc """
  Shell command for tmux panes that should enter the Casein-integrated shell.

  Follows the user's login shell: when `$SHELL` is zsh (the macOS default) and
  the staged ZDOTDIR is materialized, panes get integrated zsh; otherwise the
  integrated-bash chain applies. The command intentionally falls back to a
  normal login shell when no materialized integration is available in the
  pane's execution context (for example a container-owned tmux server without
  the host shim directory).
  """
  @spec shell_command() :: String.t()
  def shell_command do
    "sh -lc " <> shell_quote(@shell_command_body)
  end

  @doc """
  Per-viewer terminal scheme variables for tmux session env and agent launches.

  `COLORFGBG` follows the de-facto vim convention (`0;15` light, `15;0` dark).
  """
  @spec theme_env(:dark | :light, String.t() | nil) :: %{String.t() => String.t()}
  def theme_env(scheme, preset \\ nil) when scheme in [:dark, :light] do
    %{
      "CASEIN_TERMINAL_SCHEME" => Atom.to_string(scheme),
      "COLORFGBG" => colorfgbg_for_scheme(scheme),
      "COLORTERM" => "truecolor"
    }
    |> maybe_put_preset(preset)
  end

  @doc """
  Returns environment variables for Casein terminal panes.

  Pass `scheme:` / `preset:` to include per-viewer theme variables
  (`CASEIN_TERMINAL_SCHEME`, `COLORFGBG`, optional `CASEIN_TERMINAL_PRESET`).

  `include_path?: false` is useful for execution contexts where the host shim
  directory may not be mounted, such as container-owned tmux servers.

  This is a pure accessor: it does no filesystem work. Shim self-healing lives
  in `sync_tmux_terminal_env!/1` (the heal+publish entry point) so hot callers
  like `exec_env/1` do not pay a shim-heal on every read.
  """
  @spec env(keyword()) :: %{String.t() => String.t()}
  def env(opts \\ []) do
    _ = materialize!()

    base =
      opts
      |> Keyword.take([:scheme, :preset])
      |> then(fn theme_opts ->
        case Keyword.get(theme_opts, :scheme) do
          scheme when scheme in [:dark, :light] ->
            Map.merge(capability_env(), theme_env(scheme, Keyword.get(theme_opts, :preset)))

          _ ->
            capability_env()
        end
      end)

    if Keyword.get(opts, :include_path?, true) do
      Map.put(base, "PATH", path_with_shims())
    else
      base
    end
  end

  @doc """
  Heal agent launcher shims and publish the current pane env to `:tmux_ctl`.

  `TmuxCtl.Client` reads `:terminal_env` for every `new-session` / `new-window` /
  `split-window` (`-e KEY=value`) and for `apply_defaults/1` session
  `set-environment`. Refreshing here closes the race where a fresh pane is
  created before LiveView `PaneEnv.ensure_for_session/3` runs.
  """
  @spec sync_tmux_terminal_env!(keyword()) :: %{String.t() => String.t()}
  def sync_tmux_terminal_env!(opts \\ []) do
    _ = Casein.Agents.AgentShims.ensure_best_effort()
    terminal_env = env(opts)
    Application.put_env(:tmux_ctl, :terminal_env, terminal_env)
    terminal_env
  end

  @doc "Environment list for erlexec."
  @spec exec_env(keyword()) :: [{charlist(), charlist()}]
  def exec_env(opts \\ []) do
    env(opts)
    |> Enum.map(fn {key, value} -> {to_charlist(key), to_charlist(value)} end)
  end

  @doc "Environment arguments for an argv-style `env` command."
  @spec argv_env(keyword()) :: [String.t()]
  def argv_env(opts \\ []) do
    env(opts)
    |> Enum.map(fn {key, value} -> "#{key}=#{value}" end)
  end

  @doc "Environment flags for tmux commands that accept repeated `-e KEY=value`."
  @spec tmux_env_flags(keyword()) :: [String.t()]
  def tmux_env_flags(opts \\ []) do
    env(opts)
    |> Enum.flat_map(fn {key, value} -> ["-e", "#{key}=#{value}"] end)
  end

  @doc "Materialize shims for the given command names, defaulting to all shim-enabled entries."
  @spec materialize!([String.t()], keyword()) :: :ok
  # Shim dir comes from trusted operator/app configuration, not web input.
  # sobelow_skip ["Traversal.FileModule"]
  def materialize!(apps \\ shim_apps(), opts \\ []) when is_list(apps) do
    shim_dir = dir()
    install_dir = Path.join(shim_dir, "install")
    File.mkdir_p!(shim_dir)
    File.mkdir_p!(install_dir)
    write_shell_integration!(shim_dir)

    Enum.each(apps, fn name ->
      spec = Map.fetch!(@registry, name)

      # Never write a shim for `shim: false` entries (e.g. grok) even when
      # requested explicitly — the shim dir is first on PATH and would shadow
      # the real launcher.
      if Map.get(spec, :shim, true) do
        write_install_script!(install_dir, name, spec)
        write_shim!(shim_dir, name, spec)
      end
    end)

    if Keyword.get(opts, :desktop?, desktop_integration_enabled?()) do
      write_desktop_integration!()
    end

    :ok
  end

  defp shim_apps, do: for({name, spec} <- @registry, Map.get(spec, :shim, true), do: name)

  @doc false
  @spec path_with_shims(String.t() | nil) :: String.t()
  def path_with_shims(path \\ System.get_env("PATH")) do
    base =
      case path do
        value when is_binary(value) and value != "" -> value
        _ -> @default_path
      end

    # Terminal shims first (elio/casein-open), then tools, then agent launcher
    # shims + npm package bins so panes can find `claude`/`grok` without
    # relying on bashrc. Agent bins must precede npm bins so Casein shims win
    # over bare package symlinks (MCP injection).
    agent_bins = Casein.Agents.AgentShims.bin_dir()
    npm_bins = Casein.Agents.AgentShims.npm_bin_dir()

    [dir(), tools_bin_dir(), agent_bins, npm_bins | String.split(base, ":", trim: true)]
    |> Enum.uniq()
    |> Enum.join(":")
  end

  # Shim dir comes from trusted operator/app configuration, not web input.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_shell_integration!(shim_dir) do
    write_executable!(Path.join(shim_dir, @shell_integration_name), shell_integration_script())
    write_executable!(Path.join(shim_dir, @zsh_integration_name), zsh_integration_script())

    zdotdir = Path.join(shim_dir, @zdotdir_name)
    File.mkdir_p!(zdotdir)

    Enum.each(zdotdir_files(), fn {name, content} ->
      write_executable!(Path.join(zdotdir, name), content)
    end)
  end

  # Command names and install metadata are registry-backed and validated before
  # joining with shim_dir.
  defp write_install_script!(install_dir, name, spec) do
    validate_name!(name)

    write_executable!(Path.join(install_dir, name), install_script(name, Map.get(spec, :install)))
  end

  # Command names are registry-backed and validated before joining with shim_dir.
  defp write_shim!(shim_dir, name, %{env: env} = spec) when is_map(env) do
    validate_name!(name)
    Enum.each(env, fn {key, _value} -> validate_env_key!(key) end)

    write_executable!(Path.join(shim_dir, name), shim_script(name, spec))
  end

  # Skips the write when the on-disk file already matches content and mode:
  # materialize!/1 runs on every env/1 call (pane spawns, argv builds), so the
  # steady state must cost a stat + read, not a write + chmod + rename.
  # Paths are built from registry-validated names joined with operator-configured
  # dirs, not web input.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_executable!(path, content) do
    if executable_current?(path, content) do
      :ok
    else
      tmp = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

      try do
        File.write!(tmp, content)
        File.chmod!(tmp, 0o755)
        File.rename!(tmp, path)
      after
        if File.exists?(tmp), do: File.rm(tmp)
      end
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp executable_current?(path, content) do
    with {:ok, %File.Stat{mode: mode}} <- File.stat(path),
         true <- Bitwise.band(mode, 0o777) == 0o755,
         {:ok, existing} <- File.read(path) do
      existing == content
    else
      _ -> false
    end
  end

  defp shim_script("casein-open", %{script: :casein_open}) do
    """
    #!/bin/sh
    set -eu

    target="${1:-}"
    if [ -z "$target" ]; then
      echo "usage: casein-open <target>" >&2
      exit 64
    fi

    api_base="${CASEIN_API_BASE_URL:-}"
    workspace_id="${CASEIN_WORKSPACE_ID:-}"
    token="${CASEIN_API_TOKEN:-}"

    if [ -z "$api_base" ]; then
      echo "casein-open: CASEIN_API_BASE_URL is not set" >&2
      exit 64
    fi

    if [ -z "$workspace_id" ]; then
      echo "casein-open: CASEIN_WORKSPACE_ID is not set" >&2
      exit 64
    fi

    if [ -z "$token" ]; then
      echo "casein-open: CASEIN_API_TOKEN is not set" >&2
      exit 64
    fi

    json_escape() {
      name="$1"
      value="$2"
      stripped="$(printf '%s' "$value" | LC_ALL=C tr -d '\\001-\\037\\177')"
      if [ "$stripped" != "$value" ]; then
        echo "casein-open: ${name} contains unsupported control characters" >&2
        exit 64
      fi

      printf '%s' "$value" | sed 's/\\\\/\\\\\\\\/g; s/"/\\\\"/g'
    }

    escaped_target="$(json_escape target "$target")"
    escaped_base_dir="$(json_escape base_dir "${PWD:-}")"
    payload="{\\"target\\":\\"${escaped_target}\\",\\"base_dir\\":\\"${escaped_base_dir}\\"}"
    response_file="${TMPDIR:-/tmp}/casein-open.$$"
    trap 'rm -f "$response_file"' EXIT HUP INT TERM

    status="$(
      curl -sS -o "$response_file" -w '%{http_code}' \\
        --max-time 5 \\
        -X POST "${api_base%/}/api/workspaces/${workspace_id}/open" \\
        -H "authorization: Bearer ${token}" \\
        -H "content-type: application/json" \\
        --data "$payload"
    )" || {
      code=$?
      if [ -s "$response_file" ]; then
        cat "$response_file" >&2
        echo >&2
      fi
      exit "$code"
    }

    if [ "$status" = "200" ]; then
      echo "Opened ${target} in Casein viewer"
      exit 0
    fi

    if [ -s "$response_file" ]; then
      cat "$response_file" >&2
      echo >&2
    else
      echo "casein-open: request failed with HTTP ${status}" >&2
    fi

    exit 1
    """
  end

  defp shim_script(name, spec) do
    %{env: env} = spec
    bin = spec |> Map.get(:install, %{}) |> Map.get(:bin, name)
    validate_name!(bin)

    env_exports =
      env
      |> Enum.sort()
      |> Enum.map_join("\n", fn {key, value} ->
        """
        if [[ -z "${#{key}+x}" ]]; then
          export #{key}=#{shell_quote(value)}
        else
          export #{key}
        fi
        """
      end)

    """
    #!/usr/bin/env bash
    set -euo pipefail

    shim_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
    installer="${shim_dir}/install/#{name}"
    if [[ -n "${CASEIN_TERMINAL_TOOLS_DIR:-}" ]]; then
      tool_root="${CASEIN_TERMINAL_TOOLS_DIR}"
    else
      tool_root=#{shell_quote(tool_root())}
    fi
    tool_bin="${tool_root}/bin"

    clean_path=""
    old_ifs="${IFS}"
    IFS=:
    for path_part in ${PATH:-#{@default_path}}; do
      if [[ -n "$path_part" && "$path_part" != "$shim_dir" ]]; then
        if [[ -n "$clean_path" ]]; then
          clean_path="${clean_path}:$path_part"
        else
          clean_path="$path_part"
        fi
      fi
    done
    IFS="$old_ifs"

    if [[ -d "$tool_bin" ]]; then
      clean_path="${tool_bin}${clean_path:+:$clean_path}"
    fi

    resolve_real_cmd() {
      PATH="$clean_path" command -v #{shell_quote(name)} 2>/dev/null || true
    }

    real_cmd="$(resolve_real_cmd)"
    if [[ -z "$real_cmd" ]]; then
      echo "Casein: #{name} not found. Installing into ${tool_root}..." >&2

      installed=0
      if PATH="$clean_path" command -v casein >/dev/null 2>&1; then
        if CASEIN_TERMINAL_SHIMS_DIR="$shim_dir" CASEIN_TERMINAL_TOOLS_DIR="$tool_root" PATH="$clean_path" casein ensure-installed #{shell_quote(name)}; then
          installed=1
        fi
      fi

      if [[ "$installed" != "1" ]]; then
        if [[ -x "$installer" ]]; then
          "$installer"
        else
          echo "casein-shim: no installer available for #{name} at $installer" >&2
          exit 127
        fi
      fi

      real_cmd="$(resolve_real_cmd)"
      if [[ -z "$real_cmd" && -x "${tool_bin}/#{bin}" ]]; then
        real_cmd="${tool_bin}/#{bin}"
      fi

      if [[ -z "$real_cmd" ]]; then
        echo "casein-shim: installed #{name}, but it is still not executable in PATH" >&2
        exit 127
      fi

      echo "Casein: #{name} installed. Launching..." >&2
    fi

    if [[ -z "${COLORFGBG+x}" ]]; then
      case "${CASEIN_TERMINAL_SCHEME:-}" in
        light) export COLORFGBG=#{shell_quote(colorfgbg_for_scheme(:light))} ;;
        dark) export COLORFGBG=#{shell_quote(colorfgbg_for_scheme(:dark))} ;;
      esac
    else
      export COLORFGBG
    fi

    #{env_exports}
    export CASEIN_APP_SHIM=#{shell_quote(name)}
    export CASEIN_TERMINAL="${CASEIN_TERMINAL:-1}"
    export CASEIN_CLIPBOARD="${CASEIN_CLIPBOARD:-osc52}"

    exec "$real_cmd" "$@"
    """
  end

  defp shell_integration_script do
    """
    #!/usr/bin/env bash

    # Bash reads --init-file instead of its normal startup files. Source the
    # user's profile first, then install Casein's prompt/command markers.
    if [[ -z "${CASEIN_SHELL_INTEGRATION_SKIP_RC:-}" && -z "${CASEIN_SHELL_INTEGRATION_RC_SOURCED:-}" ]]; then
      export CASEIN_SHELL_INTEGRATION_RC_SOURCED=1

      if [[ -r /etc/profile ]]; then
        source /etc/profile
      fi

      if [[ -r "${HOME:-}/.bash_profile" ]]; then
        source "${HOME}/.bash_profile"
      elif [[ -r "${HOME:-}/.bash_login" ]]; then
        source "${HOME}/.bash_login"
      elif [[ -r "${HOME:-}/.profile" ]]; then
        source "${HOME}/.profile"
      elif [[ -r "${HOME:-}/.bashrc" ]]; then
        source "${HOME}/.bashrc"
      fi

      unset CASEIN_SHELL_INTEGRATION_RC_SOURCED
    fi

    # Casein dirs must be at the FRONT of PATH, not merely present: the user
    # rc files sourced above prepend agent-installer dirs (~/.grok/bin,
    # ~/.opencode/bin, …) over the pane env, and an agent name resolving past
    # ~/.casein/agent-shims silently skips MCP injection. So strip existing
    # occurrences and re-prepend, instead of skipping dirs already on PATH.
    # Order matches path_with_shims/1 — terminal shims, tools, agent launchers,
    # then npm package bins (so Casein shims win over bare package symlinks);
    # ~/.local/bin rides along for user tools on thin release PATHs.
    __casein_prepend_path() {
      # Build the new prefix in ARGUMENT order so the first arg ends up at
      # the FRONT of PATH. Kept POSIX-ish (no indirect expansion) for
      # bash + zsh.
      local d prefix="" rest=":${PATH}:"
      for d in "$@"; do
        [[ -n "${d}" && -d "${d}" ]] || continue
        case ":${prefix}:" in
          *":${d}:"*) continue ;;
        esac
        while [[ "${rest}" == *":${d}:"* ]]; do rest="${rest/:${d}:/:}"; done
        prefix="${prefix:+${prefix}:}${d}"
      done
      rest="${rest#:}"
      rest="${rest%:}"
      [[ -n "${prefix}" ]] && PATH="${prefix}${rest:+:${rest}}"
      export PATH
    }
    __casein_prepend_path \\
      "${HOME:-}/.casein/terminal-shims" \\
      "${HOME:-}/.casein/tools/bin" \\
      "${CASEIN_AGENT_BIN_DIR:-${HOME:-}/.casein/agent-shims}" \\
      "${HOME:-}/.local/share/npm-global/bin" \\
      "${HOME:-}/.local/bin"
    unset -f __casein_prepend_path

    #{session_env_sync_snippet()}
    case "$-" in
      *i*) ;;
      *) return 0 2>/dev/null || exit 0 ;;
    esac

    if [[ "${CASEIN_SHELL_INTEGRATION_LOADED:-}" == "1" ]]; then
      return 0 2>/dev/null || exit 0
    fi
    export CASEIN_SHELL_INTEGRATION_LOADED=1

    __casein_urlencode() {
      local value="${1:-}"
      local encoded=""
      local i char hex
      local LC_ALL=C

      for ((i = 0; i < ${#value}; i++)); do
        char="${value:i:1}"
        case "$char" in
          [a-zA-Z0-9.~_-]) encoded+="$char" ;;
          /) encoded+="/" ;;
          *) printf -v hex '%%%02X' "'$char"; encoded+="$hex" ;;
        esac
      done

      printf '%s' "$encoded"
    }

    __casein_emit_osc() {
      local payload="$1"
      printf '\\033]%s\\a' "$payload"

      if [[ -n "${TMUX:-}" ]]; then
        # tmux consumes plain OSC 133 for its own prompt marks. A passthrough
        # copy reaches Casein's attached client/emulator.
        printf '\\033Ptmux;\\033\\033]%s\\a\\033\\\\' "$payload"
      fi
    }

    __casein_prompt_end_sequence() {
      __casein_emit_osc "133;B"
    }

    __casein_emit_cwd() {
      local host="${HOSTNAME:-}"
      if [[ -z "$host" ]] && command -v hostname >/dev/null 2>&1; then
        host="$(hostname 2>/dev/null || true)"
      fi
      host="${host:-localhost}"

      __casein_emit_osc "7;file://${host}$(__casein_urlencode "${PWD:-/}")"
    }

    __casein_original_prompt_command="${PROMPT_COMMAND:-}"
    __casein_command_active=0
    __casein_in_prompt_command=0
    __casein_in_preexec=0

    __casein_run_original_prompt_command() {
      if [[ -n "${__casein_original_prompt_command:-}" ]]; then
        eval "$__casein_original_prompt_command"
      fi
    }

    __casein_prompt_command() {
      local status=$?
      __casein_in_prompt_command=1

      # A pane can be created in the same tick PaneEnv pushes the session env;
      # retry until the workspace vars land, then this is a no-op forever.
      __casein_sync_session_env_if_pending

      __casein_run_original_prompt_command

      if [[ "${__casein_command_active:-0}" == "1" ]]; then
        __casein_emit_osc "133;D;${status}"
        __casein_command_active=0
      fi

      __casein_emit_osc "133;A"
      __casein_emit_cwd
      __casein_in_prompt_command=0

      return "$status"
    }

    __casein_preexec() {
      local status=$?

      if [[ "${__casein_in_prompt_command:-0}" == "1" || "${__casein_in_preexec:-0}" == "1" || "${__casein_command_active:-0}" == "1" ]]; then
        return "$status"
      fi

      local command="${BASH_COMMAND:-}"
      if [[ -z "$command" || "$command" == __casein_* ]]; then
        return "$status"
      fi

      __casein_in_preexec=1
      __casein_command_active=1
      __casein_emit_osc "133;C;cmd=$(__casein_urlencode "$command")"
      __casein_in_preexec=0

      return "$status"
    }

    PROMPT_COMMAND=__casein_prompt_command

    if [[ -n "${PS1:-}" ]]; then
      __casein_prompt_end="$(__casein_prompt_end_sequence)"
      # The tmux passthrough ends with ST (ESC backslash). Prompt expansion
      # would merge that raw backslash with the closing \] into \\ + a literal
      # "]" printed after every prompt, so double every backslash and let
      # expansion collapse them back.
      PS1="${PS1}\\[${__casein_prompt_end//\\\\/\\\\\\\\}\\]"
      unset __casein_prompt_end
    fi

    # The DEBUG trap must be the LAST thing this file installs: it fires for
    # every remaining top-level command in the file, and anything traced here
    # would be recorded as a junk command in every new shell.
    trap '__casein_preexec' DEBUG
    """
  end

  # Hydrates CASEIN_* from the tmux session environment table.
  #
  # `tmux set-environment` only seeds panes created *after* the call, so a pane
  # whose shell started before `PaneEnv.ensure_for_session/3` ran keeps whatever
  # env the tmux server was launched with — on a release box that is the global
  # server env: no CASEIN_WORKSPACE_ID / MCP URLs, and the *global* admin
  # CASEIN_API_TOKEN, which MCP tools/call rejects. Every agent launcher then
  # refuses to start ("CASEIN_WORKSPACE_NAME is required").
  #
  # Shared verbatim by the bash and zsh integrations: sync once at shell init,
  # then retry on each prompt until the pairing vars land (self-disabling, so
  # steady state costs nothing). `casein_sync_session_env` is deliberately
  # un-prefixed — repair tooling and operators call it by name in live panes.
  defp session_env_sync_snippet do
    """
    casein_sync_session_env() {
      [ -n "${TMUX:-}" ] || return 0
      command -v tmux >/dev/null 2>&1 || return 0

      local __casein_line __casein_key __casein_value
      # Optional: only re-export token/URL keys after the first full sync so a
      # later workspace api-token rotate rebinds live shells without relaunch.
      local __casein_token_only="${1:-}"

      while IFS= read -r __casein_line; do
        case "$__casein_line" in
          -CASEIN_*)
            # tmux marks removed variables with a leading '-'.
            unset "${__casein_line#-}" 2>/dev/null || true
            continue
            ;;
          CASEIN_*=*) ;;
          *) continue ;;
        esac

        __casein_key="${__casein_line%%=*}"
        __casein_value="${__casein_line#*=}"

        case "$__casein_key" in
          # Shell-integration bookkeeping is per-shell, never session state.
          CASEIN_SHELL_INTEGRATION_LOADED | CASEIN_SHELL_INTEGRATION_RC_SOURCED) continue ;;
        esac

        if [ "$__casein_token_only" = "token" ]; then
          case "$__casein_key" in
            CASEIN_API_TOKEN | CASEIN_TERMINAL_MCP_URL | CASEIN_PREVIEW_MCP_URL | CASEIN_ARTIFACT_MCP_URL | CASEIN_API_BASE_URL | CASEIN_AGENT_ENV_FILE) ;;
            *) continue ;;
          esac
        fi

        export "$__casein_key=$__casein_value"
      done <<CASEIN_SESSION_ENV
    $(tmux show-environment 2>/dev/null)
    CASEIN_SESSION_ENV

      if [ -n "${CASEIN_WORKSPACE_ID:-}" ]; then
        __casein_session_env_synced=1
      fi

      return 0
    }

    __casein_sync_session_env_if_pending() {
      if [ "${__casein_session_env_synced:-0}" = "1" ]; then
        # Full map already landed — keep CASEIN_API_TOKEN fresh after rotation.
        casein_sync_session_env token
        return 0
      fi
      casein_sync_session_env
    }

    __casein_session_env_synced=0
    casein_sync_session_env
    """
  end

  # Same OSC 133 prompt marks / OSC 7 cwd contract as the bash integration,
  # implemented with zsh's native precmd/preexec hooks instead of
  # PROMPT_COMMAND + a DEBUG trap. Loaded by the staged ZDOTDIR's .zshrc after
  # the user's real ~/.zshrc, so user prompt customization gets the end mark.
  defp zsh_integration_script do
    """
    #!/usr/bin/env zsh

    [[ -o interactive ]] || return 0

    if (( ${+functions[__casein_precmd]} )); then
      return 0
    fi
    typeset -g CASEIN_SHELL_INTEGRATION_LOADED=1

    # Belt-and-suspenders PATH repair, mirroring the bash integration: keep
    # Casein shims findable even when the pane inherited a thin release PATH.
    __casein_prepend_path() {
      local d
      local -a prefix rest
      rest=("${(@s/:/)PATH}")
      for d in "$@"; do
        [[ -n "${d}" && -d "${d}" ]] || continue
        (( ${prefix[(Ie)${d}]} )) && continue
        rest=("${(@)rest:#${d}}")
        prefix+=("${d}")
      done
      PATH="${(j/:/)prefix}${rest:+:${(j/:/)rest}}"
      export PATH
    }
    __casein_prepend_path \\
      "${HOME:-}/.casein/terminal-shims" \\
      "${HOME:-}/.casein/tools/bin" \\
      "${CASEIN_AGENT_BIN_DIR:-${HOME:-}/.casein/agent-shims}" \\
      "${HOME:-}/.local/share/npm-global/bin" \\
      "${HOME:-}/.local/bin"
    unset -f __casein_prepend_path

    #{session_env_sync_snippet()}
    __casein_urlencode() {
      local value="${1:-}"
      local encoded=""
      local i char hex
      local LC_ALL=C

      for ((i = 0; i < ${#value}; i++)); do
        char="${value:$i:1}"
        case "$char" in
          [a-zA-Z0-9.~_-]) encoded+="$char" ;;
          /) encoded+="/" ;;
          *) printf -v hex '%%%02X' "'$char"; encoded+="$hex" ;;
        esac
      done

      printf '%s' "$encoded"
    }

    __casein_emit_osc() {
      local payload="$1"
      printf '\\033]%s\\a' "$payload"

      if [[ -n "${TMUX:-}" ]]; then
        # tmux consumes plain OSC 133 for its own prompt marks. A passthrough
        # copy reaches Casein's attached client/emulator.
        printf '\\033Ptmux;\\033\\033]%s\\a\\033\\\\' "$payload"
      fi
    }

    __casein_emit_cwd() {
      local host="${HOST:-}"
      if [[ -z "$host" ]] && command -v hostname >/dev/null 2>&1; then
        host="$(hostname 2>/dev/null || true)"
      fi
      host="${host:-localhost}"

      __casein_emit_osc "7;file://${host}$(__casein_urlencode "${PWD:-/}")"
    }

    __casein_command_active=0

    __casein_precmd() {
      local exit_status=$?

      # Mirrors the bash PROMPT_COMMAND retry: close the pane-create race.
      __casein_sync_session_env_if_pending

      if [[ "${__casein_command_active:-0}" == "1" ]]; then
        __casein_emit_osc "133;D;${exit_status}"
        __casein_command_active=0
      fi

      __casein_emit_osc "133;A"
      __casein_emit_cwd
    }

    __casein_preexec() {
      local command="${1:-}"

      if [[ -z "$command" || "$command" == __casein_* ]]; then
        return 0
      fi

      __casein_command_active=1
      __casein_emit_osc "133;C;cmd=$(__casein_urlencode "$command")"
    }

    autoload -Uz add-zsh-hook
    add-zsh-hook precmd __casein_precmd
    add-zsh-hook preexec __casein_preexec

    # %{...%} marks the sequence zero-width; the payload contains no % or $
    # characters, so neither prompt expansion nor PROMPT_SUBST can mangle it.
    __casein_prompt_end="$(__casein_emit_osc "133;B")"
    PS1="${PS1}%{${__casein_prompt_end}%}"
    unset __casein_prompt_end
    """
  end

  # zsh reads its dotfiles from $ZDOTDIR; the pane command execs
  # `ZDOTDIR=<staged> zsh -il`, so these wrappers run instead of the user's
  # files and chain to them. .zshrc restores the original ZDOTDIR before the
  # user's rc runs, so nested shells and .zlogin resolve normally.
  defp zdotdir_files do
    [
      {".zshenv",
       """
       # Chain through the user's original ZDOTDIR, then force the staged root
       # back so a user .zshenv that changes ZDOTDIR cannot skip our wrappers.
       export CASEIN_USER_ZDOTDIR="${CASEIN_USER_ZDOTDIR:-${HOME}}"
       export CASEIN_SHELL_INTEGRATION_ZDOTDIR="${CASEIN_SHELL_INTEGRATION_ZDOTDIR:-${ZDOTDIR}}"
       if [[ -z "${CASEIN_SHELL_INTEGRATION_SKIP_RC:-}" && -r "${CASEIN_USER_ZDOTDIR}/.zshenv" ]]; then
         source "${CASEIN_USER_ZDOTDIR}/.zshenv"
       fi
       export ZDOTDIR="${CASEIN_SHELL_INTEGRATION_ZDOTDIR}"
       """},
      {".zprofile",
       """
       # Staged by Casein (ZDOTDIR bootstrap) — chain to the user's real .zprofile.
       if [[ -z "${CASEIN_SHELL_INTEGRATION_SKIP_RC:-}" && -r "${CASEIN_USER_ZDOTDIR}/.zprofile" ]]; then
         source "${CASEIN_USER_ZDOTDIR}/.zprofile"
       fi
       export ZDOTDIR="${CASEIN_SHELL_INTEGRATION_ZDOTDIR}"
       """},
      {".zshrc",
       """
       # Staged by Casein (ZDOTDIR bootstrap) — restore the user's ZDOTDIR,
       # chain to their real ~/.zshrc, then load Casein shell integration.
       __casein_user_zdotdir="${CASEIN_USER_ZDOTDIR:-${HOME}}"
       if [[ "${__casein_user_zdotdir}" != "${HOME}" ]]; then
         export ZDOTDIR="${__casein_user_zdotdir}"
       else
         unset ZDOTDIR
       fi

       if [[ -z "${CASEIN_SHELL_INTEGRATION_SKIP_RC:-}" && -r "${__casein_user_zdotdir}/.zshrc" ]]; then
         source "${__casein_user_zdotdir}/.zshrc"
       fi

       if [[ -r "${CASEIN_SHELL_INTEGRATION_ZSH:-}" ]]; then
         source "${CASEIN_SHELL_INTEGRATION_ZSH}"
       else
         # Fall back to the integration file next to this staged directory.
         __casein_zdotdir="${${(%):-%x}:A:h}"
         if [[ -r "${__casein_zdotdir}/../shell-integration.zsh" ]]; then
           source "${__casein_zdotdir}/../shell-integration.zsh"
         fi
         unset __casein_zdotdir
       fi
       unset CASEIN_USER_ZDOTDIR __casein_user_zdotdir
       """}
    ]
  end

  defp install_script(name, nil) do
    """
    #!/usr/bin/env bash
    set -euo pipefail
    echo "casein-shim: no installer is registered for #{name}" >&2
    exit 127
    """
  end

  defp install_script(name, %{method: :cargo, package: package, bin: bin}) do
    validate_name!(package)
    validate_name!(bin)

    """
    #!/usr/bin/env bash
    set -euo pipefail

    if [[ -n "${CASEIN_TERMINAL_TOOLS_DIR:-}" ]]; then
      tool_root="${CASEIN_TERMINAL_TOOLS_DIR}"
    else
      tool_root=#{shell_quote(tool_root())}
    fi
    tool_bin="${tool_root}/bin"
    lock_timeout="${CASEIN_TERMINAL_INSTALL_LOCK_TIMEOUT_SECONDS:-600}"
    install_lock_dir=""
    mkdir -p "$tool_bin"

    if [[ -x "${tool_bin}/#{bin}" ]]; then
      echo "Casein: terminal tool '#{name}' already installed at ${tool_bin}/#{bin}" >&2
      exit 0
    fi

    install_with_cargo() {
      local tmp_root=""
      local tmp_bin=""

      cargo_cmd=()
      if command -v cargo >/dev/null 2>&1; then
        cargo_cmd=(cargo)
      elif command -v mise >/dev/null 2>&1; then
        cargo_cmd=(mise exec -y rust@stable -- cargo)
      else
        echo "Casein: cannot install #{name}; cargo is not installed and mise is unavailable." >&2
        return 127
      fi

      tmp_root="$(mktemp -d "${tool_root}/.install-#{name}.XXXXXX")"
      tmp_bin="${tool_bin}/.#{bin}.$$"

      echo "Casein: provisioning terminal tool '#{name}' via cargo package '#{package}'." >&2
      echo "Casein: cargo output follows; first install can take a few minutes." >&2
      if ! "${cargo_cmd[@]}" install --root "$tmp_root" #{shell_quote(package)}; then
        rm -rf "$tmp_root"
        rm -f "$tmp_bin"
        echo "Casein: failed to provision terminal tool '#{name}'." >&2
        return 1
      fi

      if [[ ! -x "${tmp_root}/bin/#{bin}" ]]; then
        echo "Casein: cargo install finished, but ${tmp_root}/bin/#{bin} is missing or not executable." >&2
        rm -rf "$tmp_root"
        rm -f "$tmp_bin"
        return 127
      fi

      if ! cp "${tmp_root}/bin/#{bin}" "$tmp_bin" || ! chmod +x "$tmp_bin" || ! mv -f "$tmp_bin" "${tool_bin}/#{bin}"; then
        rm -rf "$tmp_root"
        rm -f "$tmp_bin"
        echo "Casein: failed to publish terminal tool '#{name}' into ${tool_bin}." >&2
        return 1
      fi

      rm -rf "$tmp_root"
      rm -f "$tmp_bin"
      echo "Casein: provisioned terminal tool '#{name}' at ${tool_bin}/#{bin}" >&2
    }

    lock_dir="${tool_root}/.#{name}-install.lock"
    if mkdir "$lock_dir" 2>/dev/null; then
      install_lock_dir="$lock_dir"
      trap 'rm -rf "${install_lock_dir:-}"' EXIT

      if [[ -x "${tool_bin}/#{bin}" ]]; then
        echo "Casein: terminal tool '#{name}' already installed at ${tool_bin}/#{bin}" >&2
        exit 0
      fi

      install_with_cargo
      exit $?
    fi

    echo "Casein: terminal tool '#{name}' is already being installed; waiting..." >&2
    deadline=$((SECONDS + lock_timeout))
    while (( SECONDS < deadline )); do
      if [[ -x "${tool_bin}/#{bin}" ]]; then
        echo "Casein: terminal tool '#{name}' already installed at ${tool_bin}/#{bin}" >&2
        exit 0
      fi

      if [[ ! -d "$lock_dir" ]] && mkdir "$lock_dir" 2>/dev/null; then
        install_lock_dir="$lock_dir"
        trap 'rm -rf "${install_lock_dir:-}"' EXIT

        if [[ -x "${tool_bin}/#{bin}" ]]; then
          echo "Casein: terminal tool '#{name}' already installed at ${tool_bin}/#{bin}" >&2
          exit 0
        fi

        install_with_cargo
        exit $?
      fi

      sleep 1
    done

    echo "Casein: timed out waiting for terminal tool '#{name}' install lock at ${lock_dir}" >&2
    exit 75
    """
  end

  # Desktop paths come from trusted operator/app configuration or XDG/HOME.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_desktop_integration! do
    applications_dir = desktop_entries_dir()
    desktop_path = Path.join(applications_dir, "casein-preview.desktop")

    File.mkdir_p!(applications_dir)
    File.write!(desktop_path, desktop_entry())
    File.chmod!(desktop_path, 0o644)

    write_mimeapps_defaults!(mimeapps_path(), %{
      "text/markdown" => "casein-preview.desktop",
      "text/x-markdown" => "casein-preview.desktop"
    })
  end

  defp desktop_entry do
    """
    [Desktop Entry]
    Type=Application
    Name=Casein Preview
    Exec=casein-open %f
    Terminal=true
    MimeType=text/markdown;text/x-markdown;
    Categories=Utility;TextEditor;
    NoDisplay=false
    """
  end

  # Mimeapps path comes from trusted operator/app configuration or XDG/HOME.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_mimeapps_defaults!(path, defaults) do
    File.mkdir_p!(Path.dirname(path))

    existing =
      if File.exists?(path) do
        File.read!(path)
      else
        ""
      end

    File.write!(path, merge_mimeapps_defaults(existing, defaults))
  end

  defp merge_mimeapps_defaults(existing, defaults) do
    {before_default, default_lines, after_default} = split_default_applications(existing)

    merged =
      default_lines
      |> Enum.reject(fn line ->
        key = line |> String.split("=", parts: 2) |> List.first()
        Map.has_key?(defaults, key)
      end)
      |> Kernel.++(Enum.map(defaults, fn {mime, desktop} -> "#{mime}=#{desktop}" end))

    [
      trim_trailing_blank(before_default),
      "[Default Applications]\n",
      Enum.map_join(merged, "\n", & &1),
      "\n",
      after_default
    ]
    |> IO.iodata_to_binary()
    |> String.replace(~r/\n{3,}/, "\n\n")
  end

  defp split_default_applications(existing) do
    lines = String.split(existing, "\n", trim: false)

    case Enum.find_index(lines, &(&1 == "[Default Applications]")) do
      nil ->
        {ensure_section_gap(existing), [], ""}

      index ->
        {before_lines, [_header | rest]} = Enum.split(lines, index)
        {default_lines, after_lines} = Enum.split_while(rest, &(not section_header?(&1)))

        default_lines =
          default_lines
          |> Enum.reject(&(&1 == ""))
          |> Enum.reject(&String.starts_with?(&1, "#"))

        before = Enum.join(before_lines, "\n")
        before = if before == "", do: "", else: before <> "\n\n"
        after_section = Enum.join(after_lines, "\n")
        {before, default_lines, after_section}
    end
  end

  defp section_header?("[" <> rest), do: String.ends_with?(rest, "]")
  defp section_header?(_), do: false

  defp ensure_section_gap(""), do: ""
  defp ensure_section_gap(existing), do: String.trim_trailing(existing) <> "\n\n"

  defp trim_trailing_blank(""), do: ""
  defp trim_trailing_blank(value), do: String.trim_trailing(value) <> "\n\n"

  defp desktop_integration_enabled? do
    case Application.get_env(:casein, :terminal_desktop_integration_enabled) do
      nil -> System.get_env("CASEIN_TERMINAL_DESKTOP_INTEGRATION") not in ["0", "false", "no"]
      value -> !!value
    end
  end

  defp desktop_entries_dir do
    Application.get_env(:casein, :terminal_desktop_entries_dir) ||
      case System.get_env("XDG_DATA_HOME") do
        value when is_binary(value) and value != "" -> Path.join(value, "applications")
        _ -> Path.join(home_dir(), ".local/share/applications")
      end
  end

  defp mimeapps_path do
    Application.get_env(:casein, :terminal_mimeapps_path) ||
      case System.get_env("XDG_CONFIG_HOME") do
        value when is_binary(value) and value != "" -> Path.join(value, "mimeapps.list")
        _ -> Path.join(home_dir(), ".config/mimeapps.list")
      end
  end

  defp home_dir, do: Casein.Paths.home!()

  defp validate_name!(name) when is_binary(name) do
    if Regex.match?(~r/^[A-Za-z0-9._+-]+$/, name) do
      :ok
    else
      raise ArgumentError, "invalid shim command name: #{inspect(name)}"
    end
  end

  defp validate_env_key!(key) when is_binary(key) do
    if Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, key) do
      :ok
    else
      raise ArgumentError, "invalid shim env key: #{inspect(key)}"
    end
  end

  defp shell_quote(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end

  defp colorfgbg_for_scheme(:light), do: "0;15"
  defp colorfgbg_for_scheme(:dark), do: "15;0"

  defp maybe_put_preset(env, preset) when is_binary(preset) and preset != "" do
    Map.put(env, "CASEIN_TERMINAL_PRESET", preset)
  end

  defp maybe_put_preset(env, _), do: env

  defp non_empty_or(value, _fallback) when is_binary(value) and value != "", do: value
  defp non_empty_or(_value, fallback), do: fallback
end
