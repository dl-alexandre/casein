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
  @capability_env %{
    "DEV_IDE_TERMINAL" => "1",
    "DEV_IDE_CLIPBOARD" => "osc52"
  }
  @registry %{
    "elio" => %{
      env: %{"ELIO_CLIPBOARD_OSC52" => "1"},
      install: %{method: :cargo, package: "elio", bin: "elio"},
      requires: ["osc52"],
      notes: "Use browser clipboard through DevIDE's OSC52 bridge."
    }
  }

  @type install_spec :: %{
          method: :cargo,
          package: String.t(),
          bin: String.t()
        }

  @type shim_spec :: %{
          optional(:install) => install_spec(),
          env: %{String.t() => String.t()},
          requires: [String.t()],
          notes: String.t() | nil
        }

  @doc "Known terminal shims keyed by command name."
  @spec registry() :: %{String.t() => shim_spec()}
  def registry, do: @registry

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

  @doc "Absolute path to a materialized installer backend for a shimmed tool."
  @spec install_script_path(String.t()) :: String.t()
  def install_script_path(name) when is_binary(name), do: Path.join([dir(), "install", name])

  @doc "Generic terminal capability variables safe for every DevIDE pane."
  @spec capability_env() :: %{String.t() => String.t()}
  def capability_env, do: @capability_env

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
            Map.merge(@capability_env, theme_env(scheme, Keyword.get(theme_opts, :preset)))

          _ ->
            @capability_env
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

  @doc "Materialize shims for the given command names, defaulting to all known shims."
  @spec materialize!([String.t()]) :: :ok
  # Shim dir comes from trusted operator/app configuration, not web input.
  # sobelow_skip ["Traversal.FileModule"]
  def materialize!(apps \\ Map.keys(@registry)) when is_list(apps) do
    shim_dir = dir()
    install_dir = Path.join(shim_dir, "install")
    File.mkdir_p!(shim_dir)
    File.mkdir_p!(install_dir)

    Enum.each(apps, fn name ->
      spec = Map.fetch!(@registry, name)
      write_install_script!(install_dir, name, spec)
      write_shim!(shim_dir, name, spec)
    end)

    :ok
  end

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

  # Command names and install metadata are registry-backed and validated before
  # joining with shim_dir.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_install_script!(install_dir, name, spec) do
    validate_name!(name)

    path = Path.join(install_dir, name)
    tmp = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    try do
      File.write!(tmp, install_script(name, Map.get(spec, :install)))
      File.chmod!(tmp, 0o755)
      File.rename!(tmp, path)
    after
      if File.exists?(tmp), do: File.rm(tmp)
    end
  end

  # Command names are registry-backed and validated before joining with shim_dir.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_shim!(shim_dir, name, %{env: env} = spec) when is_map(env) do
    validate_name!(name)
    Enum.each(env, fn {key, _value} -> validate_env_key!(key) end)

    path = Path.join(shim_dir, name)
    tmp = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    try do
      File.write!(tmp, shim_script(name, spec))
      File.chmod!(tmp, 0o755)
      File.rename!(tmp, path)
    after
      if File.exists?(tmp), do: File.rm(tmp)
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

    #{env_exports}
    export DEV_IDE_APP_SHIM=#{shell_quote(name)}
    export DEV_IDE_TERMINAL="${DEV_IDE_TERMINAL:-1}"
    export DEV_IDE_CLIPBOARD="${DEV_IDE_CLIPBOARD:-osc52}"

    exec "$real_cmd" "$@"
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
