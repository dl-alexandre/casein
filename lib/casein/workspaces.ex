defmodule Casein.Workspaces do
  @moduledoc """
  Public workspaces facade.

  Returns `Casein.Workspace` values from the configured
  `Casein.WorkspaceSource` backend. The default source
  (`Casein.WorkspaceSource.Local`) discovers workspaces as directories
  under `:casein, :workspaces_root`; production deployments select a
  different source via config — see that module's docstring.

  All consumers (LiveViews, channels, plugs) should depend on this
  module — never on a specific source implementation.
  """

  alias Casein.{Workspace, WorkspaceSource}
  alias Casein.Workspaces.{DbIsolation, Scratch, State}
  alias Casein.Workspaces.State.WorkspaceRecord

  @type auth :: WorkspaceSource.auth()

  @spec list(keyword(), auth()) :: {:ok, [Workspace.t()]} | {:error, term()}
  def list(opts \\ [], auth \\ nil) do
    case WorkspaceSource.impl().list(opts, auth) do
      {:ok, workspaces} = ok ->
        # Batched persistence: two adapter round trips for the whole list
        # instead of a get + upsert per workspace (see State.sync_many/1).
        _ = State.sync_many(workspaces)
        ok

      other ->
        other
    end
  end

  @spec get(String.t(), auth()) :: {:ok, Workspace.t()} | {:error, term()}
  def get(id, auth \\ nil) do
    # Scratch is a synthetic workspaceless terminal (PTY at $HOME). Resolve
    # before folder-attach / source lookup so the cockpit can mount
    # `/workspaces/__scratch__` without a persisted workspace record.
    if Scratch.scratch?(id) do
      {:ok, Scratch.workspace()}
    else
      # Folder-attach workspaces have a "folder:" prefix. They bypass the source
      # (which knows nothing about arbitrary paths) and are reconstructed directly
      # from the encoded path, falling back to the persisted record if available.
      case decode_folder_id(id) do
        path when is_binary(path) ->
          cond do
            not File.dir?(path) ->
              {:error, :not_found}

            not path_under_allowed_roots?(path) ->
              {:error, :outside_allowed_roots}

            true ->
              ws = build_attached_workspace(path)
              _ = State.sync(ws)
              {:ok, ws}
          end

        nil ->
          case WorkspaceSource.impl().get(id, auth) do
            {:ok, ws} = ok ->
              _ = State.sync(ws)
              ok

            other ->
              other
          end
      end
    end
  end

  def create(params, auth \\ nil), do: WorkspaceSource.impl().create(params, auth)
  def start(id, auth \\ nil), do: WorkspaceSource.impl().start(id, auth)
  def stop(id, auth \\ nil), do: WorkspaceSource.impl().stop(id, auth)
  def delete(id, opts \\ [], auth \\ nil), do: WorkspaceSource.impl().delete(id, opts, auth)

  def create_form_fields, do: WorkspaceSource.create_form_fields()

  @doc "Persisted workspace records known to Casein."
  @spec list_records() :: [WorkspaceRecord.t()]
  def list_records, do: State.list()

  @spec list_records(keyword()) :: [WorkspaceRecord.t()]
  def list_records(opts) when is_list(opts), do: State.list(opts)

  @doc "Fetch one persisted workspace record by external workspace id."
  @spec get_record(String.t()) :: {:ok, WorkspaceRecord.t()} | :error
  def get_record(external_id), do: State.get(external_id)

  @doc "Resolve the effective workspace mode and source."
  @spec mode_for(String.t()) ::
          {Casein.Policy.WorkspaceMode.t(), :config_override | :persisted | :default}
  def mode_for(external_id), do: State.mode_for(external_id)

  @doc "Persist a manual workspace mode change."
  @spec set_mode(String.t(), Casein.Policy.WorkspaceMode.t()) ::
          {:ok, WorkspaceRecord.t()} | {:error, term()}
  def set_mode(external_id, mode), do: State.set_mode(external_id, mode)

  @doc "Subscribe the caller to workspace mode changes."
  @spec subscribe_mode_changes(String.t()) :: :ok | {:error, term()}
  def subscribe_mode_changes(external_id), do: State.subscribe_mode_changes(external_id)

  @doc "Persist the latest workspace DB isolation snapshot."
  @spec persist_isolation(String.t(), DbIsolation.t()) ::
          {:ok, WorkspaceRecord.t()} | {:error, term()}
  def persist_isolation(external_id, %DbIsolation{} = iso),
    do: State.persist_isolation(external_id, iso)

  def stream_logs(id, service, pid \\ self()),
    do: WorkspaceSource.impl().stream_logs(id, service, pid)

  @doc """
  True when `username` owns `workspace`. Pure comparison; callers decide
  *whether* to enforce ownership (e.g. forward-auth mode).
  """
  @spec owns?(Workspace.t() | map(), String.t()) :: boolean()
  def owns?(%{user: ws_user}, username) when is_binary(ws_user) and is_binary(username),
    do: ws_user == username

  def owns?(_, _), do: false

  @doc """
  True when `viewer` may open or use a workspace in the multi-user cockpit.

  **Flat peer model:** any authenticated identity (has `id` / `username` /
  `email`) may access every workspace. Casein does not elevate an "admin"
  role over peers and does not owner-gate shared surfaces (artifacts, preview
  proxy, terminals, files). The outer gate is oauth2-proxy / API token auth —
  once you're in, peers are equal. Unauthenticated or empty maps are denied.

  There is intentionally **no** unused ownership predicate next to this gate
  (#928). Owner string comparison for forward-auth email derivation remains
  `owns?/2`; do not invent a parallel "viewer_owns" helper that is tested but
  never called — readers will assume ownership is enforced somewhere.
  """
  @spec viewer_can_access_workspace?(Workspace.t() | map(), map()) :: boolean()
  def viewer_can_access_workspace?(_workspace, viewer) when is_map(viewer) do
    authenticated_viewer?(viewer)
  end

  def viewer_can_access_workspace?(_, _), do: false

  @doc """
  True when the viewer may use terminal capabilities (raw fast path and
  capability tokens). Same flat peer rule as `viewer_can_access_workspace?/2`.
  """
  @spec viewer_terminal_owner?(Workspace.t() | map(), map()) :: boolean()
  def viewer_terminal_owner?(workspace, viewer) when is_map(viewer) do
    viewer_can_access_workspace?(workspace, viewer)
  end

  def viewer_terminal_owner?(_, _), do: false

  @doc """
  Derive an `X-Auth-Request-Email` value for workspace-scoped preview fetches.

  Uses the workspace owner's manager username plus
  `:forward_auth_email_domain` (env `CASEIN_FORWARD_AUTH_EMAIL_DOMAIN`).
  """
  @spec forward_auth_email(Workspace.t() | map()) :: String.t() | nil
  def forward_auth_email(workspace) do
    case workspace_owner(workspace) do
      owner when is_binary(owner) and owner != "" ->
        domain = forward_auth_email_domain()

        if is_binary(domain) and domain != "" do
          owner |> String.downcase() |> then(&"#{&1}@#{domain}")
        end

      _ ->
        nil
    end
  end

  @doc "Forward-auth headers for preview MCP when the caller sends none."
  @spec forward_auth_headers(Workspace.t() | map()) :: %{String.t() => String.t()} | nil
  def forward_auth_headers(workspace) do
    case forward_auth_email(workspace) do
      email when is_binary(email) -> %{"X-Auth-Request-Email" => email}
      _ -> nil
    end
  end

  defp workspace_owner(workspace) when is_map(workspace) do
    Map.get(workspace, :user) || Map.get(workspace, "user") ||
      metadata_value(workspace, :user)
  end

  defp metadata_value(workspace, :user) when is_map(workspace) do
    metadata = Map.get(workspace, :metadata) || Map.get(workspace, "metadata") || %{}

    Map.get(metadata, :user) || Map.get(metadata, "user") ||
      get_in(metadata, [:raw, :user]) || get_in(metadata, ["raw", "user"]) ||
      get_in(metadata, [:raw, "user"])
  end

  defp map_string_or_atom(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  # Identity present after ForwardAuth / session — not an empty map spoof.
  defp authenticated_viewer?(viewer) when is_map(viewer) do
    [
      map_string_or_atom(viewer, :id),
      map_string_or_atom(viewer, :username),
      map_string_or_atom(viewer, :email)
    ]
    |> Enum.any?(fn
      v when is_binary(v) -> String.trim(v) != ""
      _ -> false
    end)
  end

  defp forward_auth_email_domain do
    Application.get_env(:casein, :forward_auth_email_domain) ||
      System.get_env("CASEIN_FORWARD_AUTH_EMAIL_DOMAIN")
  end

  @spec safe_host_path(Workspace.t() | map()) :: {:ok, String.t()} | {:error, atom()}
  def safe_host_path(%Workspace{metadata: %{attached_folder: true}, path: path})
      when is_binary(path) do
    expanded = Path.expand(path)

    if File.dir?(expanded) do
      {:ok, expanded}
    else
      {:error, :not_found}
    end
  end

  def safe_host_path(%Workspace{} = workspace) do
    if Scratch.scratch?(workspace) do
      home = Scratch.home_path()

      if File.dir?(home) do
        {:ok, home}
      else
        {:error, :not_found}
      end
    else
      WorkspaceSource.impl().safe_host_path(workspace)
    end
  end

  def safe_host_path(workspace), do: WorkspaceSource.impl().safe_host_path(workspace)

  @typedoc "Where a workspace physically lives."
  @type workspace_loc :: {:local, String.t()} | {:remote, String.t(), String.t()}

  @spec safe_host_loc(Workspace.t() | map()) ::
          {:ok, workspace_loc()} | {:error, atom()}
  def safe_host_loc(%Workspace{metadata: %{attached_folder: true}, path: path})
      when is_binary(path) do
    expanded = Path.expand(path)

    if File.dir?(expanded) do
      {:ok, {:local, expanded}}
    else
      {:error, :not_found}
    end
  end

  def safe_host_loc(%Workspace{} = workspace) do
    if Scratch.scratch?(workspace) do
      home = Scratch.home_path()

      if File.dir?(home) do
        {:ok, {:local, home}}
      else
        {:error, :not_found}
      end
    else
      WorkspaceSource.impl().safe_host_loc(workspace)
    end
  end

  def safe_host_loc(workspace), do: WorkspaceSource.impl().safe_host_loc(workspace)

  @doc """
  Attach to an arbitrary local folder path and return a `%Workspace{}` for it.

  The workspace id is a URL-safe base64 encoding of the absolute path so it
  round-trips cleanly through the router. The workspace is synced into state
  so the cockpit can look it up via `get/2`.

  Returns `{:error, :not_a_directory}` when the path does not point to an
  existing directory.
  """
  @spec attach_folder(String.t()) :: {:ok, Workspace.t()} | {:error, atom()}
  def attach_folder(path) when is_binary(path) do
    expanded = Path.expand(path)

    cond do
      not File.dir?(expanded) ->
        {:error, :not_a_directory}

      not path_under_allowed_roots?(expanded) ->
        {:error, :outside_allowed_roots}

      true ->
        ws = build_attached_workspace(expanded)
        _ = State.sync(ws)
        {:ok, ws}
    end
  end

  @doc """
  Resolve a local folder path to a workspace, preferring the configured synthetic
  `home` workspace when the path is exactly `:home_workspace_path`.

  When a persisted record matches the path with a manager (non-`folder:`)
  external id, the workspace resolves to that stable identity — so path URLs
  and `/workspaces/:id` opens of the same directory share tmux sessions,
  topics, and tokens. A stale record (manager no longer knows the id) falls
  back to folder attach; transport errors propagate rather than silently
  forking identity into a `folder:` id.
  """
  @spec workspace_for_host_path(String.t()) :: {:ok, Workspace.t()} | {:error, atom()}
  def workspace_for_host_path(path) when is_binary(path) do
    expanded = Path.expand(path)

    case home_workspace_for_path(expanded) do
      {:ok, workspace} -> {:ok, workspace}
      :not_home -> recorded_workspace_or_attach(expanded)
      {:error, _reason} -> recorded_workspace_or_attach(expanded)
    end
  end

  defp recorded_workspace_or_attach(expanded) do
    case recorded_external_id(expanded) do
      nil ->
        attach_folder(expanded)

      external_id ->
        case get(external_id) do
          {:ok, _workspace} = ok -> ok
          {:error, :not_found} -> attach_folder(expanded)
          {:error, _reason} = error -> error
        end
    end
  end

  defp recorded_external_id(expanded) do
    case State.records_for_host_paths([expanded]) do
      %{^expanded => %WorkspaceRecord{external_id: "folder:" <> _}} ->
        nil

      %{^expanded => %WorkspaceRecord{external_id: external_id}} when is_binary(external_id) ->
        external_id

      _ ->
        nil
    end
  end

  @type folder_entry :: %{
          name: String.t(),
          path: String.t()
        }

  @type folder_listing :: %{
          path: String.t(),
          parent: String.t() | nil,
          roots: [String.t()],
          entries: [folder_entry()]
        }

  @doc """
  Lists child directories for the allowed-root folder browser.

  Passing `nil` starts at the first configured allowed root. Every requested
  path must stay inside `allowed_roots/0`.
  """
  @spec list_attachable_folders(String.t() | nil) :: {:ok, folder_listing()} | {:error, atom()}
  def list_attachable_folders(path \\ nil) do
    roots = allowed_roots()
    current = path || List.first(roots)

    cond do
      is_nil(current) ->
        {:error, :not_found}

      not path_under_allowed_roots?(current) ->
        {:error, :outside_allowed_roots}

      not File.dir?(current) ->
        {:error, :not_a_directory}

      true ->
        expanded = Path.expand(current)

        case File.ls(expanded) do
          {:ok, names} ->
            entries =
              names
              |> Enum.map(&Path.join(expanded, &1))
              |> Enum.filter(&(File.dir?(&1) and path_under_allowed_roots?(&1)))
              |> Enum.map(&%{name: Path.basename(&1), path: &1})
              |> Enum.sort_by(&String.downcase(&1.name))

            {:ok,
             %{
               path: expanded,
               parent: browser_parent(expanded),
               roots: roots,
               entries: entries
             }}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Returns the absolute path encoded in a folder-attach workspace id, or `nil`
  when the id is not a folder-attach id.
  """
  @spec decode_folder_id(String.t()) :: String.t() | nil
  def decode_folder_id("folder:" <> encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, path} -> path
      _ -> nil
    end
  end

  def decode_folder_id(_), do: nil

  defp build_attached_workspace(expanded_path) do
    id = "folder:" <> Base.url_encode64(expanded_path, padding: false)
    name = Path.basename(expanded_path)

    %Workspace{
      id: id,
      name: name,
      user: owner_from_path(expanded_path),
      branch: detect_branch(expanded_path),
      status: :running,
      path: expanded_path,
      metadata: %{attached_folder: true}
    }
  end

  defp home_workspace_for_path(expanded_path) do
    case Application.get_env(:casein, :home_workspace_path) do
      home when is_binary(home) and home != "" ->
        if Path.expand(home) == expanded_path do
          get("home")
        else
          :not_home
        end

      _ ->
        :not_home
    end
  end

  # Derive the workspace owner from the devbox `/<root>/<user>/<project>` layout:
  # the first path segment under the matching allowed root. Returns nil when the
  # path equals the root, has no segment, or is under no allowed root — preserving
  # the prior `user: nil` behavior for non-`/<user>/` layouts. This mirrors the
  # existing ownership convention (manager workspaces for the same paths already
  # carry this owner) and does not widen access: attach is already gated by
  # path_under_allowed_roots?/1 and preview MCP endpoints are pre-scoped to one
  # workspace.
  defp owner_from_path(expanded_path) when is_binary(expanded_path) do
    Enum.find_value(allowed_roots(), fn root ->
      if String.starts_with?(expanded_path, root <> "/") do
        expanded_path
        |> Path.relative_to(root)
        |> Path.split()
        |> List.first()
      end
    end)
  end

  defp detect_branch(path) do
    case System.cmd("git", ["-C", path, "branch", "--show-current"], stderr_to_stdout: true) do
      {out, 0} -> out |> String.trim() |> then(fn s -> if s == "", do: nil, else: s end)
      _ -> nil
    end
  rescue
    ErlangError -> nil
  end

  @doc """
  Filesystem roots a workspace path may live under. Generic across sources.
  Configure with `:casein, :workspaces_root`, the additive
  `:workspaces_roots` list, and optional `:home_workspace_path`.

  Includes `:lan_path_root` when set, so any path that resolves through
  `Casein.Workspaces.PathResolver` is by construction attachable — the URL
  resolver and the attach gate cannot disagree.
  """
  @spec allowed_roots() :: [String.t()]
  def allowed_roots do
    config = Application.get_env(:casein, :workspaces_roots) || []
    primary = Application.get_env(:casein, :workspaces_root) || "/workspaces"
    home = Application.get_env(:casein, :home_workspace_path)
    path_root = Application.get_env(:casein, :lan_path_root)

    [primary, home, path_root | config]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.map(&Path.expand/1)
  end

  @doc false
  def path_under_allowed_roots?(path) when is_binary(path) do
    expanded = Path.expand(path)

    Enum.any?(allowed_roots(), fn root ->
      expanded == root or String.starts_with?(expanded, root <> "/")
    end)
  end

  defp browser_parent(path) do
    parent = Path.dirname(path)

    cond do
      parent == path -> nil
      path_under_allowed_roots?(parent) -> parent
      true -> nil
    end
  end
end
