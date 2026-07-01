defmodule DevIDE.Agents.AuthProfile do
  @moduledoc """
  Opt-in workspace-scoped and shared auth homes for external agent CLIs.

  Profiles are activated by directory presence. New installs use:

      ~/.devide/agent-auth/workspaces/<workspace-key>/<runtime>
      ~/.devide/agent-auth/profiles/<profile-key>/<runtime>

  `profiles/<owner>/<runtime>` is an owner default: a workspace named
  `sconde-test` can reuse `profiles/sconde/<runtime>` without one login per
  workspace. Legacy `~/.devide/agent-auth/<workspace-key>/<runtime>` directories
  are still honored.

  If no directory exists, DevIDE leaves that runtime on its normal global auth
  state. This keeps existing workspaces unchanged while allowing selected
  workspaces to use separate Claude or Codex subscriptions.
  """

  @type runtime :: :claude | :codex
  @type env_map :: %{String.t() => String.t()}

  @runtimes [:claude, :codex]

  @doc "Returns provider env vars when an explicit profile exists, otherwise `%{}`."
  @spec env_for_workspace(map() | struct() | String.t(), runtime()) :: env_map()
  def env_for_workspace(workspace, runtime) when runtime in @runtimes do
    case active_profile_dir(workspace, runtime) do
      nil ->
        %{}

      dir ->
        if File.dir?(dir), do: %{env_key(runtime) => dir}, else: %{}
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

  @doc "Returns the deterministic workspace profile directory for a workspace/runtime."
  @spec profile_dir(map() | struct() | String.t(), runtime()) :: String.t() | nil
  def profile_dir(workspace, runtime) when runtime in @runtimes do
    with key when is_binary(key) <- workspace_key(workspace) do
      Path.join([auth_root(), "workspaces", key, Atom.to_string(runtime)])
    end
  end

  def profile_dir(_workspace, _runtime), do: nil

  @doc "Returns the deterministic shared profile directory for a named profile/runtime."
  @spec named_profile_dir(String.t(), runtime()) :: String.t() | nil
  def named_profile_dir(profile, runtime) when runtime in @runtimes do
    with key when is_binary(key) <- slugify(profile) do
      Path.join([auth_root(), "profiles", key, Atom.to_string(runtime)])
    end
  end

  def named_profile_dir(_profile, _runtime), do: nil

  @doc "Returns the active directory used for workspace/runtime auth, if any."
  @spec active_profile_dir(map() | struct() | String.t(), runtime()) :: String.t() | nil
  def active_profile_dir(workspace, runtime) when runtime in @runtimes do
    workspace
    |> candidate_profile_dirs(runtime)
    |> Enum.find(&File.dir?/1)
  end

  def active_profile_dir(_workspace, _runtime), do: nil

  @doc "Creates a profile directory and seeds a short README explaining isolation."
  @spec ensure_profile_dir!(map() | struct() | String.t(), runtime()) :: String.t()
  # Profile dirs are rooted under the configured DevIDE auth-profile root after slugging workspace keys.
  # sobelow_skip ["Traversal.FileModule"]
  def ensure_profile_dir!(workspace, runtime) when runtime in @runtimes do
    dir = profile_dir(workspace, runtime) || raise ArgumentError, "invalid workspace"
    File.mkdir_p!(dir)
    seed_readme(dir, runtime)
    dir
  end

  @doc "Creates a shared profile directory and seeds a short README explaining isolation."
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

  @doc "Best-effort owner slug used for shared profile fallback."
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

  defp candidate_profile_dirs(workspace, runtime) do
    [
      profile_dir(workspace, runtime),
      owner_profile_dir(workspace, runtime),
      legacy_profile_dir(workspace, runtime)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp owner_profile_dir(workspace, runtime) do
    with key when is_binary(key) <- owner_key(workspace) do
      named_profile_dir(key, runtime)
    end
  end

  defp legacy_profile_dir(workspace, runtime) do
    with key when is_binary(key) <- workspace_key(workspace) do
      Path.join([auth_root(), key, Atom.to_string(runtime)])
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

  # Profile dirs are rooted under the configured DevIDE auth-profile root after slugging workspace keys.
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
    DevIDE #{runtime} auth profile

    This directory is an opt-in workspace-scoped auth home. While it exists,
    DevIDE launches #{runtime} for this workspace with this directory as the
    provider auth/config root. Delete the directory to return the workspace to
    the global provider login.

    This isolates provider auth, but it may also isolate provider-local config,
    logs, sessions, and runtime state.
    """
  end
end
