defmodule DevIDE.Agents.AuthProfile do
  @moduledoc """
  Required owner auth homes for external agent CLIs.

  DevIDE launches Claude and Codex with owner-scoped provider homes:

      ~/.devide/agent-auth/profiles/<owner-key>/<runtime>

  A workspace named `sconde-test` reuses `profiles/sconde/<runtime>` without one
  login per workspace.

  The directory is the provider home, not proof of completed sign-in. Missing
  directories are created during pane/MCP env materialization so agent launches
  do not inherit the host's global Claude/Codex login.
  """

  @type runtime :: :claude | :codex
  @type env_map :: %{String.t() => String.t()}

  @runtimes [:claude, :codex]

  @doc "Returns provider env vars for the workspace owner, creating the profile home."
  @spec env_for_workspace(map() | struct() | String.t(), runtime()) :: env_map()
  def env_for_workspace(workspace, runtime) when runtime in @runtimes do
    case owner_profile_dir(workspace, runtime) do
      nil -> %{}
      dir -> %{env_key(runtime) => ensure_profile_dir!(dir, runtime)}
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

  @doc "Returns the owner profile directory used for workspace/runtime auth, if resolvable."
  @spec active_profile_dir(map() | struct() | String.t(), runtime()) :: String.t() | nil
  def active_profile_dir(workspace, runtime) when runtime in @runtimes do
    owner_profile_dir(workspace, runtime)
  end

  def active_profile_dir(_workspace, _runtime), do: nil

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
  defp ensure_profile_dir!(dir, runtime) do
    File.mkdir_p!(dir)
    seed_readme(dir, runtime)
    dir
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

    This directory is a DevIDE owner auth home. DevIDE launches #{runtime} for
    matching workspaces with this directory as the provider auth/config root.
    If the directory is deleted, DevIDE recreates an empty isolated home and
    #{runtime} requires sign-in again.

    This isolates provider auth, but it may also isolate provider-local config,
    logs, sessions, and runtime state.
    """
  end
end
