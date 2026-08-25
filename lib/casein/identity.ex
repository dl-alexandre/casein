defmodule Casein.Identity do
  @moduledoc """
  The one place Casein decides *which human* an agent acts as.

  Before this module existed the answer differed per subsystem, and the
  divergence was invisible in any single file:

    * Claude and Codex homes keyed on the workspace **name** prefix, so an
      agent in `dalexandre-devide` ran on dalexandre's provider account no
      matter who opened it.
    * `gh` keyed on nothing. No launcher set `GH_CONFIG_DIR`, so every agent
      fell through to the host-global `~/.config/gh` — a config dir holding
      several accounts behind a single active `user:` key. Every agent on the
      box opened PRs as whoever had logged in last.
    * Server-side `gh` calls (ticket feed, orphaned-claim reconciliation)
      hardcoded one person's config dir, so issue claims were attributed to
      them regardless of who clicked.
    * Git author came from whichever checkout the pane happened to sit in:
      `MILC Devbox`, `DevIDE Agent`, or a hand-set personal identity.

  ## Viewer-keyed

  The principal is **the viewer who launched the agent**, not the workspace
  owner. Attribution follows the human: their provider quota, their GitHub
  account on the PR, their name on the commit. Working in a colleague's
  workspace does not silently spend the colleague's identity.

  Resolution order, first hit wins:

    1. `:principal` — an explicit slug, for callers that already resolved one.
    2. `:viewer` — a `CaseinWeb.Plugs.ForwardAuth` identity map. This is the
       normal path: LiveView and controllers pass `assigns.current_user`.
    3. `CASEIN_ACTOR` — set into the pane environment at launch so shell-side
       resolution (`scripts/lib/agent-auth-profile.sh`) agrees with this
       module without re-deriving anything.
    4. `:workspace` — the workspace owner, via `AuthProfile.owner_key/1`.
       Fallback only, for callers with no viewer at all (reconcilers, smoke
       runs, `mix` tasks).

  When nothing resolves, `principal` is `nil` and every home is left unset:
  the runtime falls back to its host-global login exactly as before.

  ## The shared-session caveat

  A tmux session belongs to a workspace, not to a viewer, and `tmux
  set-environment` writes one value for the whole session. Panes read it at
  creation, so the principal baked into a pane is the viewer who last
  refreshed that session's environment — not necessarily the one typing in it
  now. Existing panes are never rewritten.

  That is a deliberate limit, not an oversight: rewriting a live pane's
  identity mid-session would silently reattribute work already in flight.
  `CASEIN_ACTOR` is therefore also *recorded* in the pane, so anything that
  needs to know who a pane is acting as can read it back rather than guess.
  """

  alias Casein.Agents.AuthProfile

  @type source :: :explicit | :viewer | :env | :workspace | :unresolved

  @type t :: %__MODULE__{
          principal: String.t() | nil,
          source: source(),
          email: String.t() | nil
        }

  defstruct principal: nil, source: :unresolved, email: nil

  @actor_env "CASEIN_ACTOR"
  @reportable_runtimes [:claude, :codex, :gh]

  @doc """
  Resolve the acting principal.

  Options: `:principal`, `:viewer`, `:workspace`, and `:env` (set `false` to
  skip the `CASEIN_ACTOR` step — used by tests and by the launcher itself,
  which must not re-read the value it is about to write).
  """
  @spec resolve(keyword()) :: t()
  def resolve(opts \\ []) when is_list(opts) do
    {principal, source} = principal_and_source(opts)

    %__MODULE__{principal: principal, source: source, email: email_for(principal, opts)}
  end

  defp principal_and_source(opts) do
    explicit = slugify(Keyword.get(opts, :principal))
    viewer = viewer_slug(Keyword.get(opts, :viewer))
    from_env = if Keyword.get(opts, :env, true), do: slugify(System.get_env(@actor_env))
    owner = workspace_slug(Keyword.get(opts, :workspace))

    cond do
      is_binary(explicit) -> {explicit, :explicit}
      is_binary(viewer) -> {viewer, :viewer}
      is_binary(from_env) -> {from_env, :env}
      is_binary(owner) -> {owner, :workspace}
      true -> {nil, :unresolved}
    end
  end

  @doc """
  Provider/tooling environment for an identity: `CLAUDE_CONFIG_DIR`,
  `CODEX_HOME`, `GH_CONFIG_DIR`, plus `CASEIN_ACTOR` and `CASEIN_ACTOR_EMAIL`.

  Keys are omitted (not blanked) when the principal has no active profile for
  that runtime, so an unresolved principal changes nothing about the launch.

  `CASEIN_ACTOR_EMAIL` is what the launcher turns into `GIT_AUTHOR_EMAIL`.
  Deriving it here rather than in shell keeps one definition of a principal's
  address — the shell would otherwise need its own copy of the forward-auth
  domain lookup and could disagree with the server about the same person.
  """
  @spec env(t() | keyword()) :: %{String.t() => String.t()}
  def env(%__MODULE__{principal: nil}), do: %{}

  def env(%__MODULE__{principal: principal, email: email}) do
    principal
    |> AuthProfile.env_for_principal()
    |> Map.put(@actor_env, principal)
    |> put_actor_email(email)
  end

  def env(opts) when is_list(opts), do: opts |> resolve() |> env()

  @doc """
  Config dir for one runtime, or `nil` to mean "use the host-global login".

  `gh` is the caller that most needs the `nil`: a server-side `gh` invocation
  with no resolvable principal must run with whatever the host provides rather
  than borrowing a named person's token.
  """
  @spec config_dir(t() | keyword(), AuthProfile.runtime()) :: String.t() | nil
  def config_dir(%__MODULE__{principal: principal}, runtime),
    do: AuthProfile.active_dir_for_principal(principal, runtime)

  def config_dir(opts, runtime) when is_list(opts), do: opts |> resolve() |> config_dir(runtime)

  @doc """
  Git author for an identity, as `{name, email}`, or `nil` when unresolved.

  Callers pass this to `git -c user.name=… -c user.email=…` per invocation
  rather than writing it into a checkout's config: a worktree is shared
  between panes and people, so a persisted author would misattribute the next
  person's commits.
  """
  @spec git_author(t() | keyword()) :: {String.t(), String.t()} | nil
  def git_author(%__MODULE__{principal: principal, email: email})
      when is_binary(principal) and is_binary(email),
      do: {principal, email}

  def git_author(%__MODULE__{}), do: nil
  def git_author(opts) when is_list(opts), do: opts |> resolve() |> git_author()

  @doc """
  Git `-c` arguments for an identity, or `[]` when unresolved.

  Empty rather than a placeholder: with no arguments git falls back to the
  checkout/global config, which is the pre-existing behaviour.
  """
  @spec git_config_args(t() | keyword()) :: [String.t()]
  def git_config_args(identity_or_opts) do
    case git_author(identity_or_opts) do
      {name, email} -> ["-c", "user.name=#{name}", "-c", "user.email=#{email}"]
      nil -> []
    end
  end

  @doc """
  Environment for a server-side `gh` invocation.

  Blanks `GH_TOKEN`/`GITHUB_TOKEN` (an ambient token silently outranks the
  config dir) and picks a config dir in this order:

    1. `:gh_config_dir` — an explicit override from the caller.
    2. The resolved principal's `gh` profile, when there is one.
    3. `:gh_service_config_dir` / `CASEIN_GH_CONFIG_DIR` — a **declared**
       service identity for calls with no human behind them.
    4. `GH_CONFIG_DIR` from the environment.

  There is deliberately no personal fallback. Both server-side `gh` callers
  used to default to one engineer's config dir, so read-only ticket listings
  and — worse — issue claim writes were attributed to them no matter who
  triggered the action. Falling through to `gh`'s own default is the honest
  behaviour: it fails visibly instead of impersonating someone.
  """
  @spec gh_env(keyword()) :: [{String.t(), String.t()}]
  def gh_env(opts \\ []) when is_list(opts) do
    base = [
      {"GH_TOKEN", ""},
      {"GITHUB_TOKEN", ""},
      {"GH_PROMPT_DISABLED", "1"},
      {"GH_NO_UPDATE_NOTIFIER", "1"}
    ]

    case gh_config_dir(opts) do
      dir when is_binary(dir) and dir != "" -> [{"GH_CONFIG_DIR", dir} | base]
      _ -> base
    end
  end

  @doc "Config dir `gh_env/1` would use, or `nil` for gh's own default."
  @spec gh_config_dir(keyword()) :: String.t() | nil
  def gh_config_dir(opts) when is_list(opts) do
    Keyword.get(opts, :gh_config_dir) ||
      config_dir(opts, :gh) ||
      Application.get_env(:casein, :gh_service_config_dir) ||
      System.get_env("CASEIN_GH_CONFIG_DIR") ||
      System.get_env("GH_CONFIG_DIR")
  end

  @doc """
  Everything the UI needs to answer "who am I acting as?" for one viewer.

  Returns the principal and, per runtime, whether it resolves to a profile
  (`:profile`), a registered profile awaiting sign-in (`:pending`), or the host
  global login (`:global`) — plus the account name where one can be read.

  `:global` is the state worth surfacing: it means that runtime is *not*
  per-person, so the agent acts as whatever the box happens to be logged into.
  That was the invisible default for `gh` on every pane.
  """
  @spec report(keyword()) :: map()
  def report(opts \\ []) when is_list(opts) do
    identity = resolve(opts)

    %{
      principal: identity.principal,
      source: identity.source,
      email: identity.email,
      runtimes: Enum.map(@reportable_runtimes, &runtime_report(identity, &1))
    }
  end

  defp runtime_report(%__MODULE__{principal: principal}, runtime) do
    dir = AuthProfile.active_dir_for_principal(principal, runtime)

    state =
      cond do
        is_nil(dir) -> :global
        AuthProfile.signed_in?(dir, runtime) -> :profile
        true -> :pending
      end

    %{runtime: runtime, state: state, dir: dir, account: account_name(runtime, dir, state)}
  end

  # The GitHub login is the one account name that is both readable and the
  # thing people actually want to check before pushing. Providers do not store
  # a comparable plaintext identifier, so they report none.
  defp account_name(:gh, dir, :profile) when is_binary(dir), do: gh_login(dir)
  defp account_name(:gh, _dir, :global), do: gh_login(global_gh_dir())
  defp account_name(_runtime, _dir, _state), do: nil

  # Deliberately NOT `System.get_env("GH_CONFIG_DIR")`. That reads the *server
  # process's* environment, which on this box is inherited from whichever pane
  # started it — so the report would show every viewer the release's own gh
  # identity and hide the account a profile-less pane actually falls back to.
  defp global_gh_dir do
    Application.get_env(:casein, :gh_global_config_dir) ||
      Path.join([home_dir(), ".config", "gh"])
  end

  # Reads only the host-level `user:` key. hosts.yml also holds oauth tokens,
  # so this must never return anything but that one identifier.
  # sobelow_skip ["Traversal.FileModule"]
  defp gh_login(dir) when is_binary(dir) do
    case File.read(Path.join(dir, "hosts.yml")) do
      {:ok, contents} ->
        case Regex.run(~r/^\s{4}user:\s*(\S+)\s*$/m, contents) do
          [_, login] -> login
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp gh_login(_dir), do: nil

  defp home_dir, do: Casein.Paths.home!()

  ## Internals

  defp put_actor_email(env, email) when is_binary(email) and email != "",
    do: Map.put(env, "CASEIN_ACTOR_EMAIL", email)

  defp put_actor_email(env, _email), do: env

  defp viewer_slug(viewer) when is_map(viewer) do
    slugify(
      Map.get(viewer, :username) || Map.get(viewer, "username") ||
        Map.get(viewer, :id) || Map.get(viewer, "id") ||
        local_part(Map.get(viewer, :email) || Map.get(viewer, "email"))
    )
  end

  defp viewer_slug(viewer) when is_binary(viewer), do: slugify(local_part(viewer))
  defp viewer_slug(_viewer), do: nil

  defp workspace_slug(nil), do: nil
  defp workspace_slug(workspace), do: AuthProfile.owner_key(workspace)

  defp local_part(email) when is_binary(email), do: email |> String.split("@") |> hd()
  defp local_part(_email), do: nil

  # The viewer's real email when we have one; otherwise synthesize it from the
  # forward-auth domain, which is how every other Casein surface addresses a
  # principal (`Casein.Workspaces.forward_auth_email/1`).
  defp email_for(nil, _opts), do: nil

  defp email_for(principal, opts) do
    case viewer_email(Keyword.get(opts, :viewer)) do
      email when is_binary(email) ->
        email

      nil ->
        case email_domain() do
          domain when is_binary(domain) and domain != "" -> "#{principal}@#{domain}"
          _ -> nil
        end
    end
  end

  defp viewer_email(viewer) when is_map(viewer) do
    case Map.get(viewer, :email) || Map.get(viewer, "email") do
      email when is_binary(email) and email != "" -> String.downcase(email)
      _ -> nil
    end
  end

  defp viewer_email(_viewer), do: nil

  defp email_domain do
    Application.get_env(:casein, :forward_auth_email_domain) ||
      System.get_env("CASEIN_FORWARD_AUTH_EMAIL_DOMAIN")
  end

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

  defp slugify(_value), do: nil
end
