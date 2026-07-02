defmodule DevIDE.Agents.AuthProfile do
  @moduledoc """
  Opt-in owner auth homes for external agent CLIs, with global-login fallback.

  Once an owner signs in, DevIDE launches Claude and Codex with owner-scoped
  provider homes:

      ~/.devide/agent-auth/profiles/<owner-key>/<runtime>

  A workspace named `sconde-test` reuses `profiles/sconde/<runtime>` without one
  login per workspace.

  A profile only activates once its directory holds provider credentials
  (`.credentials.json` for Claude, `auth.json` for Codex). A missing directory
  — or one left behind by an aborted sign-in — keeps that runtime on the host
  global provider login, so agents default to the global login until the owner
  completes `devide agent auth signin <runtime>`.
  """

  @type runtime :: :claude | :codex
  @type env_map :: %{String.t() => String.t()}

  @runtimes [:claude, :codex]

  # Same markers agent-doctor.sh checks: written by a completed provider login.
  @credential_markers %{claude: ".credentials.json", codex: "auth.json"}

  @doc "Returns provider env vars when a signed-in owner profile exists, otherwise `%{}`."
  @spec env_for_workspace(map() | struct() | String.t(), runtime()) :: env_map()
  def env_for_workspace(workspace, runtime) when runtime in @runtimes do
    case active_profile_dir(workspace, runtime) do
      nil -> %{}
      dir -> %{env_key(runtime) => dir}
    end
  end

  def env_for_workspace(_workspace, _runtime), do: %{}

  @doc "Returns all active provider env vars for a workspace."
  @spec env_for_workspace(map() | struct() | String.t()) :: env_map()
  def env_for_workspace(workspace) do
    Enum.reduce(@runtimes, %{}, fn runtime, acc ->
      Map.merge(acc, env_for_workspace(workspace, runtime))
    end)
  end

  @doc "Returns the deterministic owner profile directory for a named owner/runtime."
  @spec named_profile_dir(String.t(), runtime()) :: String.t() | nil
  def named_profile_dir(profile, runtime) when runtime in @runtimes do
    with key when is_binary(key) <- slugify(profile) do
      Path.join([auth_root(), "profiles", key, Atom.to_string(runtime)])
    end
  end

  def named_profile_dir(_profile, _runtime), do: nil

  @doc "Returns the signed-in owner profile directory used for workspace/runtime auth, if any."
  @spec active_profile_dir(map() | struct() | String.t(), runtime()) :: String.t() | nil
  def active_profile_dir(workspace, runtime) when runtime in @runtimes do
    case owner_profile_dir(workspace, runtime) do
      nil -> nil
      dir -> if signed_in?(dir, runtime), do: dir
    end
  end

  def active_profile_dir(_workspace, _runtime), do: nil

  @doc """
  Whether a profile directory holds completed provider credentials.

  A profile dir without credentials (e.g. created by an aborted sign-in) is
  not active, so launches default to the global provider login.
  """
  @spec signed_in?(String.t(), runtime()) :: boolean()
  def signed_in?(dir, runtime) when is_binary(dir) and runtime in @runtimes do
    File.exists?(Path.join(dir, Map.fetch!(@credential_markers, runtime)))
  end

  def signed_in?(_dir, _runtime), do: false

  @doc "Creates an owner profile directory and seeds a short README explaining isolation."
  @spec ensure_named_profile_dir!(String.t(), runtime()) :: String.t()
  # Profile dirs are rooted under the configured DevIDE auth-profile root after slugging profile keys.
  # sobelow_skip ["Traversal.FileModule"]
  def ensure_named_profile_dir!(profile, runtime) when runtime in @runtimes do
    dir = named_profile_dir(profile, runtime) || raise ArgumentError, "invalid profile"
    File.mkdir_p!(dir)
    seed_readme(dir, runtime)
    dir
  end

  @doc "Stable slug used in profile directory paths."
  @spec workspace_key(map() | struct() | String.t()) :: String.t() | nil
  def workspace_key(workspace) do
    workspace
    |> workspace_name()
    |> slugify()
  end

  @doc "Best-effort owner slug used for profile fallback."
  @spec owner_key(map() | struct() | String.t()) :: String.t() | nil
  def owner_key(workspace) do
    case workspace_key(workspace) do
      nil ->
        nil

      key ->
        key
        |> String.split("-", parts: 2)
        |> List.first()
        |> case do
          "" -> nil
          owner -> owner
        end
    end
  end

  defp owner_profile_dir(workspace, runtime) do
    with key when is_binary(key) <- owner_key(workspace) do
      named_profile_dir(key, runtime)
    end
  end

  defp workspace_name(value) when is_binary(value), do: value

  defp workspace_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp workspace_name(%{"name" => name}) when is_binary(name) and name != "", do: name
  defp workspace_name(%{id: id}) when is_binary(id) and id != "", do: id
  defp workspace_name(%{"id" => id}) when is_binary(id) and id != "", do: id
  defp workspace_name(_), do: nil

  defp slugify(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9._-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> nil
      slug -> slug
    end
  end

  defp slugify(_), do: nil

  defp env_key(:claude), do: "CLAUDE_CONFIG_DIR"
  defp env_key(:codex), do: "CODEX_HOME"

  defp auth_root do
    Application.get_env(:dev_ide, :agent_auth_profile_root) ||
      System.get_env("DEVIDE_AGENT_AUTH_ROOT") ||
      Path.join([home_dir(), ".devide", "agent-auth"])
  end

  defp home_dir do
    System.get_env("HOME") || "/home/devbox"
  end

  # Profile dirs are rooted under the configured DevIDE auth-profile root after slugging owner keys.
  # sobelow_skip ["Traversal.FileModule"]
  defp seed_readme(dir, runtime) do
    path = Path.join(dir, "README.devide-profile")

    if File.exists?(path) do
      :ok
    else
      File.write!(path, readme(runtime))
      File.chmod(path, 0o600)
    end

    :ok
  end

  defp readme(runtime) do
    """
    DevIDE #{runtime} owner auth profile

    This directory is an opt-in DevIDE owner auth home. Once a #{runtime}
    sign-in completes here, DevIDE launches #{runtime} for matching workspaces
    with this directory as the provider auth/config root. Until then — and
    whenever the directory is deleted — that owner stays on the host global
    provider login.

    This isolates provider auth, but it may also isolate provider-local config,
    logs, sessions, and runtime state.
    """
  end
end
