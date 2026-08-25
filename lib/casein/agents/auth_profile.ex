defmodule Casein.Agents.AuthProfile do
  @moduledoc """
  Per-person auth homes for external agent CLIs, with global-login fallback.

  Once a person signs in, Casein launches their agents with principal-scoped
  provider homes:

      ~/.casein/agent-auth/profiles/<principal>/<runtime>

  Three runtimes share the tree: `claude` (`CLAUDE_CONFIG_DIR`), `codex`
  (`CODEX_HOME`), and `gh` (`GH_CONFIG_DIR`). Keeping GitHub in the same tree
  is deliberate — before it lived here, every agent `gh` call fell through to
  the host-global `~/.config/gh`, which multiplexes several accounts behind a
  single active `user:` key, so agents opened PRs as whoever logged in last.

  **This module does not decide who the principal is.** `Casein.Identity` owns
  that (viewer-keyed, see its moduledoc); the functions here that still accept
  a workspace resolve its owner only as the last-resort fallback in that chain.

  A profile only activates once its directory holds provider credentials
  (`.credentials.json` for Claude, `auth.json` for Codex, `hosts.yml` for gh).
  A missing directory — or one left behind by an aborted sign-in — keeps that
  runtime on the host global provider login, so agents default to the global
  login until the owner completes `casein agent auth signin <runtime>`.

  Registered owners are the opt-in exception: `<auth-root>/owners` lists owner
  slugs (one per line, `#` comments) that must never fall back to the host
  global login. For a registered owner the profile dir applies even before
  sign-in, so the provider CLI prompts for its own login inside the profile.
  Setting `CASEIN_AGENT_AUTH_FALLBACK=none` treats every owner as registered.
  """

  @type runtime :: :claude | :codex | :gh
  @type env_map :: %{String.t() => String.t()}

  @runtimes [:claude, :codex, :gh]

  # Same markers agent-doctor.sh checks: written by a completed provider login.
  # `gh` writes hosts.yml only after `gh auth login` completes.
  @credential_markers %{claude: ".credentials.json", codex: "auth.json", gh: "hosts.yml"}

  @doc """
  Returns provider env vars when a signed-in owner profile exists or the
  workspace owner is registered (fail closed), otherwise `%{}`.
  """
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

  @doc """
  Returns the owner profile directory used for workspace/runtime auth, if any.

  A registered owner's profile dir is active even before sign-in — the
  provider CLI then prompts for its own login inside the profile instead of
  falling back to the host global auth.
  """
  @spec active_profile_dir(map() | struct() | String.t(), runtime()) :: String.t() | nil
  def active_profile_dir(workspace, runtime) when runtime in @runtimes do
    workspace |> owner_key() |> active_dir_for_principal(runtime)
  end

  def active_profile_dir(_workspace, _runtime), do: nil

  @doc """
  Returns the active profile dir for an already-resolved principal slug.

  This is the form `Casein.Identity` calls: the principal has already been
  chosen (viewer first, workspace owner only as fallback), so no workspace
  parsing happens here.
  """
  @spec active_dir_for_principal(String.t() | nil, runtime()) :: String.t() | nil
  def active_dir_for_principal(principal, runtime)
      when is_binary(principal) and runtime in @runtimes do
    case named_profile_dir(principal, runtime) do
      nil ->
        nil

      dir ->
        cond do
          signed_in?(dir, runtime) -> dir
          registered_principal?(principal, runtime) -> dir
          true -> nil
        end
    end
  end

  def active_dir_for_principal(_principal, _runtime), do: nil

  @doc "Provider env vars for an already-resolved principal slug."
  @spec env_for_principal(String.t() | nil, runtime()) :: env_map()
  def env_for_principal(principal, runtime) when runtime in @runtimes do
    case active_dir_for_principal(principal, runtime) do
      nil -> %{}
      dir -> %{env_key(runtime) => dir}
    end
  end

  def env_for_principal(_principal, _runtime), do: %{}

  @doc "All provider env vars for an already-resolved principal slug."
  @spec env_for_principal(String.t() | nil) :: env_map()
  def env_for_principal(principal) do
    Enum.reduce(@runtimes, %{}, fn runtime, acc ->
      Map.merge(acc, env_for_principal(principal, runtime))
    end)
  end

  @doc """
  Whether the workspace's owner is listed in `<auth-root>/owners` and must
  therefore never fall back to the host global provider login.
  """
  @spec registered_owner?(map() | struct() | String.t(), runtime() | :any) :: boolean()
  def registered_owner?(workspace, runtime \\ :any),
    do: workspace |> owner_key() |> registered_principal?(runtime)

  @doc """
  Whether a principal is registered (fail closed) for `runtime`.

  Registration is **per runtime**. An entry may name the runtimes it covers:

      dalexandre              # every runtime
      sconde:claude,codex     # gh may still fall back to the host global login

  A bare slug covers everything, which is what every pre-existing entry means.
  The per-runtime form exists because the runtimes are not interchangeable: a
  person can have a provider account without having a GitHub account on the
  box, and failing their `gh` closed would break them to protect an identity
  they do not yet have. Relaxing one runtime must not relax the others.

  `:any` asks "registered for anything at all?" — used by reporting, never to
  decide a launch.
  """
  @spec registered_principal?(String.t() | nil, runtime() | :any) :: boolean()
  def registered_principal?(principal, runtime \\ :any)

  def registered_principal?(principal, runtime) when is_binary(principal) and principal != "" do
    System.get_env("CASEIN_AGENT_AUTH_FALLBACK") == "none" or
      registered_runtime?(registered_runtimes(principal), runtime)
  end

  def registered_principal?(_principal, _runtime), do: false

  @doc """
  Runtimes a principal is registered for: `:all`, a list, or `[]` when the
  principal is not listed.
  """
  @spec registered_runtimes(String.t() | nil) :: :all | [runtime()]
  def registered_runtimes(principal) when is_binary(principal) and principal != "" do
    Map.get(owner_entries(), principal, [])
  end

  def registered_runtimes(_principal), do: []

  defp registered_runtime?(:all, _runtime), do: true
  defp registered_runtime?([], _runtime), do: false
  # Non-empty list: `:any` is satisfied by definition, otherwise membership.
  defp registered_runtime?(runtimes, :any) when is_list(runtimes), do: true
  defp registered_runtime?(runtimes, runtime) when is_list(runtimes), do: runtime in runtimes

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
  # Profile dirs are rooted under the configured Casein auth-profile root after slugging profile keys.
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

  @doc """
  Best-effort owner slug for a workspace, used only as the last fallback in
  `Casein.Identity`'s resolution chain.

  Prefers the authoritative `:user` the devbox manager sets on the workspace.
  Only when that is absent (local-source workspaces carry `user: nil`) does it
  fall back to parsing the workspace *name* up to the first `-`.

  The name parse is a heuristic and is wrong for any workspace not named
  `<person>-<topic>`: `farm-parity-fields` yields `farm`, `devbox-smoke` yields
  `devbox`. Those slugs have no profile, so they fall through to global auth
  rather than borrowing someone else's — but they are not identities, which is
  why `:user` is consulted first.

  A bare workspace **id** never produces an owner. Callers used to pass a UUID
  here, which the name parse happily reduced to its first hex group (a
  `e7c18b93-…` workspace resolved to the principal `e7c18b93`) and then looked
  up a profile dir that could never exist.
  """
  @spec owner_key(map() | struct() | String.t()) :: String.t() | nil
  def owner_key(workspace) do
    case slugify(manager_user(workspace)) do
      slug when is_binary(slug) -> slug
      nil -> owner_from_name(workspace)
    end
  end

  defp owner_from_name(workspace) do
    case workspace_key(workspace) do
      nil ->
        nil

      key ->
        if uuid_like?(key) do
          nil
        else
          key
          |> String.split("-", parts: 2)
          |> List.first()
          |> case do
            "" -> nil
            owner -> owner
          end
        end
    end
  end

  # Same lookup order as `Casein.Workspaces.workspace_owner/1` — the two must
  # agree or forward-auth preview email and agent auth would name different
  # people for one workspace.
  defp manager_user(workspace) when is_map(workspace) do
    metadata = Map.get(workspace, :metadata) || Map.get(workspace, "metadata") || %{}

    candidate =
      Map.get(workspace, :user) || Map.get(workspace, "user") ||
        Map.get(metadata, :user) || Map.get(metadata, "user") ||
        get_in(metadata, [:raw, :user]) || get_in(metadata, ["raw", "user"]) ||
        get_in(metadata, [:raw, "user"])

    case candidate do
      user when is_binary(user) and user != "" -> user
      _ -> nil
    end
  end

  defp manager_user(_workspace), do: nil

  @uuid_re ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

  defp uuid_like?(value) when is_binary(value), do: Regex.match?(@uuid_re, value)

  # Owners files are rooted under the configured Casein auth-profile root.
  # sobelow_skip ["Traversal.FileModule"]
  defp owner_entries do
    file = Path.join(auth_root(), "owners")

    case File.read(file) do
      {:ok, contents} ->
        contents
        |> String.split("\n")
        |> Enum.map(&(&1 |> String.replace(~r/#.*/, "") |> String.replace(~r/\s+/, "")))
        |> Enum.reject(&(&1 == ""))
        |> Map.new(&parse_owner_entry/1)

      _ ->
        %{}
    end
  end

  defp parse_owner_entry(entry) do
    case String.split(entry, ":", parts: 2) do
      [slug] ->
        {slug, :all}

      [slug, runtimes] ->
        parsed =
          runtimes
          |> String.split(",", trim: true)
          |> Enum.flat_map(fn name ->
            # Unknown runtime names are dropped rather than raising: this file
            # is hand-edited, and a typo must not take down every launch.
            Enum.filter(@runtimes, &(Atom.to_string(&1) == name))
          end)

        {slug, parsed}
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
  defp env_key(:gh), do: "GH_CONFIG_DIR"

  defp auth_root do
    Application.get_env(:casein, :agent_auth_profile_root) ||
      System.get_env("CASEIN_AGENT_AUTH_ROOT") ||
      Path.join([home_dir(), ".casein", "agent-auth"])
  end

  defp home_dir, do: Casein.Paths.home!()

  # Profile dirs are rooted under the configured Casein auth-profile root after slugging owner keys.
  # sobelow_skip ["Traversal.FileModule"]
  defp seed_readme(dir, runtime) do
    path = Path.join(dir, "README.casein-profile")

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
    Casein #{runtime} owner auth profile

    This directory is an opt-in Casein owner auth home. Once a #{runtime}
    sign-in completes here, Casein launches #{runtime} for matching workspaces
    with this directory as the provider auth/config root. Until then — and
    whenever the directory is deleted — that owner stays on the host global
    provider login.

    This isolates provider auth, but it may also isolate provider-local config,
    logs, sessions, and runtime state.
    """
  end
end
