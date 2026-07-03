defmodule DevIDE.Terminals.Shims do
  @moduledoc """
  Materializes DevIDE terminal command shims and exposes terminal capability env.

  The shims are intentionally scoped to DevIDE terminal panes by prepending this
  directory to pane `PATH`; the host's real binaries stay untouched and can be
  invoked directly by absolute path when debugging.
  """

  @default_dir "~/.devide/terminal-shims"
  @default_tool_root "~/.devide/tools"
  @default_path "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  @shell_integration_name "shell-integration.bash"
  @shell_command_body ~s(if [ -r "${DEV_IDE_SHELL_INTEGRATION_BASH:-}" ] && command -v bash >/dev/null 2>&1; then exec bash --init-file "$DEV_IDE_SHELL_INTEGRATION_BASH" -i; fi; if command -v bash >/dev/null 2>&1; then exec bash -l; fi; if [ -n "${SHELL:-}" ] && [ -x "$SHELL" ]; then exec "$SHELL"; fi; exec sh)
  @capability_env %{
    "DEV_IDE_TERMINAL" => "1",
    "DEV_IDE_CLIPBOARD" => "osc52",
    "DEV_IDE_SHELL_INTEGRATION" => "1"
  }
  @registry %{
    "elio" => %{
      env: %{"ELIO_CLIPBOARD_OSC52" => "1"},
      install: %{method: :cargo, package: "elio", bin: "elio"},
      requires: ["osc52"],
      notes: "Use browser clipboard through DevIDE's OSC52 bridge.",
      theme: %{
        mode: :static,
        path: "~/.config/elio/theme.toml",
        template: "tool_themes/elio/theme.toml"
      }
    },
    # grok is an agent launcher shimmed into ~/.local/bin by
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
          values: %{dark: "groknight", light: "grokday"}
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

  @doc "Directory where DevIDE materializes terminal shims."
  @spec dir() :: String.t()
  def dir do
    :dev_ide
    |> Application.get_env(:terminal_shims_dir)
    |> non_empty_or(System.get_env("DEV_IDE_TERMINAL_SHIMS_DIR"))
    |> non_empty_or(@default_dir)
    |> Path.expand()
  end

  @doc "Directory where DevIDE installs self-healed terminal tools."
  @spec tool_root() :: String.t()
  def tool_root do
    :dev_ide
    |> Application.get_env(:terminal_tools_dir)
    |> non_empty_or(System.get_env("DEV_IDE_TERMINAL_TOOLS_DIR"))
    |> non_empty_or(@default_tool_root)
    |> Path.expand()
  end

  @doc "Directory that contains DevIDE-managed terminal tool binaries."
  @spec tools_bin_dir() :: String.t()
  def tools_bin_dir, do: Path.join(tool_root(), "bin")

  @doc "Absolute path to a materialized shim."
  @spec shim_path(String.t()) :: String.t()
  def shim_path(name) when is_binary(name), do: Path.join(dir(), name)

  @doc "Absolute path to DevIDE's bash shell integration file."
  @spec shell_integration_path() :: String.t()
  def shell_integration_path, do: Path.join(dir(), @shell_integration_name)

  @doc "Absolute path to a materialized installer backend for a shimmed tool."
  @spec install_script_path(String.t()) :: String.t()
  def install_script_path(name) when is_binary(name), do: Path.join([dir(), "install", name])

  @doc "Generic terminal capability variables safe for every DevIDE pane."
  @spec capability_env() :: %{String.t() => String.t()}
  def capability_env do
    Map.put(@capability_env, "DEV_IDE_SHELL_INTEGRATION_BASH", shell_integration_path())
  end

  @doc """
  Shell command for tmux panes that should enter the DevIDE-integrated shell.

  The command intentionally falls back to a normal login shell when the
  materialized bash integration is unavailable in the pane's execution context
  (for example a container-owned tmux server without the host shim directory).
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
      "DEV_IDE_TERMINAL_SCHEME" => Atom.to_string(scheme),
      "COLORFGBG" => colorfgbg_for_scheme(scheme)
    }
    |> maybe_put_preset(preset)
  end

  @doc """
  Returns environment variables for DevIDE terminal panes.

  Pass `scheme:` / `preset:` to include per-viewer theme variables
  (`DEV_IDE_TERMINAL_SCHEME`, `COLORFGBG`, optional `DEV_IDE_TERMINAL_PRESET`).

  `include_path?: false` is useful for execution contexts where the host shim
  directory may not be mounted, such as container-owned tmux servers.
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
  @spec materialize!([String.t()]) :: :ok
  # Shim dir comes from trusted operator/app configuration, not web input.
  # sobelow_skip ["Traversal.FileModule"]
  def materialize!(apps \\ shim_apps()) when is_list(apps) do
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

    [dir(), tools_bin_dir() | String.split(base, ":", trim: true)]
    |> Enum.uniq()
    |> Enum.join(":")
  end

  # Shim dir comes from trusted operator/app configuration, not web input.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_shell_integration!(shim_dir) do
    path = Path.join(shim_dir, @shell_integration_name)
    tmp = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    try do
      File.write!(tmp, shell_integration_script())
      File.chmod!(tmp, 0o755)
      File.rename!(tmp, path)
    after
      if File.exists?(tmp), do: File.rm(tmp)
    end
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
    if [[ -n "${DEV_IDE_TERMINAL_TOOLS_DIR:-}" ]]; then
      tool_root="${DEV_IDE_TERMINAL_TOOLS_DIR}"
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
      echo "DevIDE: #{name} not found. Installing into ${tool_root}..." >&2

      installed=0
      if PATH="$clean_path" command -v devide >/dev/null 2>&1; then
        if DEV_IDE_TERMINAL_SHIMS_DIR="$shim_dir" DEV_IDE_TERMINAL_TOOLS_DIR="$tool_root" PATH="$clean_path" devide ensure-installed #{shell_quote(name)}; then
          installed=1
        fi
      fi

      if [[ "$installed" != "1" ]]; then
        if [[ -x "$installer" ]]; then
          "$installer"
        else
          echo "devide-shim: no installer available for #{name} at $installer" >&2
          exit 127
        fi
      fi

      real_cmd="$(resolve_real_cmd)"
      if [[ -z "$real_cmd" && -x "${tool_bin}/#{bin}" ]]; then
        real_cmd="${tool_bin}/#{bin}"
      fi

      if [[ -z "$real_cmd" ]]; then
        echo "devide-shim: installed #{name}, but it is still not executable in PATH" >&2
        exit 127
      fi

      echo "DevIDE: #{name} installed. Launching..." >&2
    fi

    if [[ -z "${COLORFGBG+x}" ]]; then
      case "${DEV_IDE_TERMINAL_SCHEME:-}" in
        light) export COLORFGBG=#{shell_quote(colorfgbg_for_scheme(:light))} ;;
        dark) export COLORFGBG=#{shell_quote(colorfgbg_for_scheme(:dark))} ;;
      esac
    else
      export COLORFGBG
    fi

    #{env_exports}
    export DEV_IDE_APP_SHIM=#{shell_quote(name)}
    export DEV_IDE_TERMINAL="${DEV_IDE_TERMINAL:-1}"
    export DEV_IDE_CLIPBOARD="${DEV_IDE_CLIPBOARD:-osc52}"

    exec "$real_cmd" "$@"
    """
  end

  defp shell_integration_script do
    """
    #!/usr/bin/env bash

    # Bash reads --init-file instead of its normal startup files. Source the
    # user's profile first, then install DevIDE's prompt/command markers.
    if [[ -z "${DEV_IDE_SHELL_INTEGRATION_SKIP_RC:-}" && -z "${DEV_IDE_SHELL_INTEGRATION_RC_SOURCED:-}" ]]; then
      export DEV_IDE_SHELL_INTEGRATION_RC_SOURCED=1

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

      unset DEV_IDE_SHELL_INTEGRATION_RC_SOURCED
    fi

    case "$-" in
      *i*) ;;
      *) return 0 2>/dev/null || exit 0 ;;
    esac

    if [[ "${DEV_IDE_SHELL_INTEGRATION_LOADED:-}" == "1" ]]; then
      return 0 2>/dev/null || exit 0
    fi
    export DEV_IDE_SHELL_INTEGRATION_LOADED=1

    __devide_urlencode() {
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

    __devide_emit_osc() {
      local payload="$1"
      printf '\\033]%s\\a' "$payload"

      if [[ -n "${TMUX:-}" ]]; then
        # tmux consumes plain OSC 133 for its own prompt marks. A passthrough
        # copy reaches DevIDE's attached client/emulator.
        printf '\\033Ptmux;\\033\\033]%s\\a\\033\\\\' "$payload"
      fi
    }

    __devide_prompt_end_sequence() {
      __devide_emit_osc "133;B"
    }

    __devide_emit_cwd() {
      local host="${HOSTNAME:-}"
      if [[ -z "$host" ]] && command -v hostname >/dev/null 2>&1; then
        host="$(hostname 2>/dev/null || true)"
      fi
      host="${host:-localhost}"

      __devide_emit_osc "7;file://${host}$(__devide_urlencode "${PWD:-/}")"
    }

    __devide_original_prompt_command="${PROMPT_COMMAND:-}"
    __devide_command_active=0
    __devide_in_prompt_command=0
    __devide_in_preexec=0

    __devide_run_original_prompt_command() {
      if [[ -n "${__devide_original_prompt_command:-}" ]]; then
        eval "$__devide_original_prompt_command"
      fi
    }

    __devide_prompt_command() {
      local status=$?
      __devide_in_prompt_command=1

      __devide_run_original_prompt_command

      if [[ "${__devide_command_active:-0}" == "1" ]]; then
        __devide_emit_osc "133;D;${status}"
        __devide_command_active=0
      fi

      __devide_emit_osc "133;A"
      __devide_emit_cwd
      __devide_in_prompt_command=0

      return "$status"
    }

    __devide_preexec() {
      local status=$?

      if [[ "${__devide_in_prompt_command:-0}" == "1" || "${__devide_in_preexec:-0}" == "1" || "${__devide_command_active:-0}" == "1" ]]; then
        return "$status"
      fi

      local command="${BASH_COMMAND:-}"
      if [[ -z "$command" || "$command" == __devide_* ]]; then
        return "$status"
      fi

      __devide_in_preexec=1
      __devide_command_active=1
      __devide_emit_osc "133;C;cmd=$(__devide_urlencode "$command")"
      __devide_in_preexec=0

      return "$status"
    }

    PROMPT_COMMAND=__devide_prompt_command

    if [[ -n "${PS1:-}" ]]; then
      __devide_prompt_end="$(__devide_prompt_end_sequence)"
      PS1="${PS1}\\[${__devide_prompt_end}\\]"
      unset __devide_prompt_end
    fi

    # The DEBUG trap must be the LAST thing this file installs: it fires for
    # every remaining top-level command in the file, and anything traced here
    # would be recorded as a junk command in every new shell.
    trap '__devide_preexec' DEBUG
    """
  end

  defp install_script(name, nil) do
    """
    #!/usr/bin/env bash
    set -euo pipefail
    echo "devide-shim: no installer is registered for #{name}" >&2
    exit 127
    """
  end

  defp install_script(name, %{method: :cargo, package: package, bin: bin}) do
    validate_name!(package)
    validate_name!(bin)

    """
    #!/usr/bin/env bash
    set -euo pipefail

    if [[ -n "${DEV_IDE_TERMINAL_TOOLS_DIR:-}" ]]; then
      tool_root="${DEV_IDE_TERMINAL_TOOLS_DIR}"
    else
      tool_root=#{shell_quote(tool_root())}
    fi
    tool_bin="${tool_root}/bin"
    lock_timeout="${DEV_IDE_TERMINAL_INSTALL_LOCK_TIMEOUT_SECONDS:-600}"
    install_lock_dir=""
    mkdir -p "$tool_bin"

    if [[ -x "${tool_bin}/#{bin}" ]]; then
      echo "DevIDE: terminal tool '#{name}' already installed at ${tool_bin}/#{bin}" >&2
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
        echo "DevIDE: cannot install #{name}; cargo is not installed and mise is unavailable." >&2
        return 127
      fi

      tmp_root="$(mktemp -d "${tool_root}/.install-#{name}.XXXXXX")"
      tmp_bin="${tool_bin}/.#{bin}.$$"

      echo "DevIDE: provisioning terminal tool '#{name}' via cargo package '#{package}'." >&2
      echo "DevIDE: cargo output follows; first install can take a few minutes." >&2
      if ! "${cargo_cmd[@]}" install --root "$tmp_root" #{shell_quote(package)}; then
        rm -rf "$tmp_root"
        rm -f "$tmp_bin"
        echo "DevIDE: failed to provision terminal tool '#{name}'." >&2
        return 1
      fi

      if [[ ! -x "${tmp_root}/bin/#{bin}" ]]; then
        echo "DevIDE: cargo install finished, but ${tmp_root}/bin/#{bin} is missing or not executable." >&2
        rm -rf "$tmp_root"
        rm -f "$tmp_bin"
        return 127
      fi

      if ! cp "${tmp_root}/bin/#{bin}" "$tmp_bin" || ! chmod +x "$tmp_bin" || ! mv -f "$tmp_bin" "${tool_bin}/#{bin}"; then
        rm -rf "$tmp_root"
        rm -f "$tmp_bin"
        echo "DevIDE: failed to publish terminal tool '#{name}' into ${tool_bin}." >&2
        return 1
      fi

      rm -rf "$tmp_root"
      rm -f "$tmp_bin"
      echo "DevIDE: provisioned terminal tool '#{name}' at ${tool_bin}/#{bin}" >&2
    }

    lock_dir="${tool_root}/.#{name}-install.lock"
    if mkdir "$lock_dir" 2>/dev/null; then
      install_lock_dir="$lock_dir"
      trap 'rm -rf "${install_lock_dir:-}"' EXIT

      if [[ -x "${tool_bin}/#{bin}" ]]; then
        echo "DevIDE: terminal tool '#{name}' already installed at ${tool_bin}/#{bin}" >&2
        exit 0
      fi

      install_with_cargo
      exit $?
    fi

    echo "DevIDE: terminal tool '#{name}' is already being installed; waiting..." >&2
    deadline=$((SECONDS + lock_timeout))
    while (( SECONDS < deadline )); do
      if [[ -x "${tool_bin}/#{bin}" ]]; then
        echo "DevIDE: terminal tool '#{name}' already installed at ${tool_bin}/#{bin}" >&2
        exit 0
      fi

      if [[ ! -d "$lock_dir" ]] && mkdir "$lock_dir" 2>/dev/null; then
        install_lock_dir="$lock_dir"
        trap 'rm -rf "${install_lock_dir:-}"' EXIT

        if [[ -x "${tool_bin}/#{bin}" ]]; then
          echo "DevIDE: terminal tool '#{name}' already installed at ${tool_bin}/#{bin}" >&2
          exit 0
        fi

        install_with_cargo
        exit $?
      fi

      sleep 1
    done

    echo "DevIDE: timed out waiting for terminal tool '#{name}' install lock at ${lock_dir}" >&2
    exit 75
    """
  end

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
    Map.put(env, "DEV_IDE_TERMINAL_PRESET", preset)
  end

  defp maybe_put_preset(env, _), do: env

  defp non_empty_or(value, _fallback) when is_binary(value) and value != "", do: value
  defp non_empty_or(_value, fallback), do: fallback
end
