defmodule DevIDE.Previews do
  @moduledoc """
  Preview Broker context.

  Manages browser previews (dev server tabs / in-cockpit panels) that can be
  spawned from terminal sessions, command output, annotations, workspace
  metadata surfaces, or the palette.

  Previews are the surface that makes annotations more powerful (e.g. "the
  error is visible at http://localhost:4000/..." can be turned into a live
  preview pane or tab with audit trail).
  """

  import Ecto.Query

  alias DevIDE.Audit
  alias DevIDE.Workspaces.Aliases, as: WorkspaceAliases
  alias DevIde.Repo
  alias DevIDE.Previews.{Identity, Preview, Surface, SurfaceResolver, Url}

  @type preview :: Preview.t()
  @type workspace :: map()

  @doc """
  Open a preview for a workspace.

  `attrs` should include at minimum `:url`. `:mode` (tab), `:title`,
  `:session_id`, `:pane_id`, and `:metadata` are optional.

  Trusted flag is computed for safety (only local/project-controlled URLs
  are allowed to render inside the cockpit panel).
  """
  def open(workspace, attrs) when is_map(workspace) do
    workspace_id = workspace.id || workspace[:id]
    attrs = normalize_open_attrs(workspace, attrs, workspace_id)

    case insert_preview(attrs) do
      {:ok, preview} ->
        actor_id = Map.get(attrs, :actor_id) || nil

        Audit.emit!(%{
          action: "preview.opened",
          workspace_id: workspace_id,
          actor_id: actor_id,
          target_type: "preview",
          target_ref: to_string(preview.id),
          metadata: %{
            url: preview.url,
            mode: preview.mode,
            trusted: preview.trusted,
            session_id: attrs[:session_id],
            pane_id: attrs[:pane_id],
            surface: attrs.metadata["surface"],
            surface_key: attrs.metadata["surface_key"]
          }
        })

        {:ok, preview}

      error ->
        error
    end
  end

  @doc "Find an open preview for this workspace surface/origin, or insert one."
  def find_or_open(workspace, attrs) when is_map(workspace) do
    workspace_id = workspace.id || workspace[:id]
    attrs = normalize_open_attrs(workspace, attrs, workspace_id)

    case find_open_for_attrs(workspace_id, attrs) do
      %Preview{} = preview -> {:ok, preview}
      nil -> open(workspace, attrs)
    end
  end

  @doc "Open a named manager/terminal surface as a preview record."
  def open_surface(workspace, surface_name, attrs \\ []) when is_map(workspace) do
    attrs = Map.new(attrs)

    case SurfaceResolver.get(workspace, surface_name) do
      %Surface{} = surface ->
        control_url = Map.get(attrs, :control_url, surface.url)
        display_url = Map.get(attrs, :url, SurfaceResolver.embed_url(workspace, surface))

        metadata =
          attrs
          |> Map.get(:metadata, %{})
          |> Map.put("surface", surface.name)
          |> Map.put("surface_source", Atom.to_string(surface.source))
          |> Map.put("control_url", control_url)
          |> Map.put("display_url", display_url)

        find_or_open(workspace, %{
          url: display_url,
          title: surface.title,
          mode: Map.get(attrs, :mode, :tab),
          actor_id: Map.get(attrs, :actor_id),
          session_id: Map.get(attrs, :session_id),
          pane_id: Map.get(attrs, :pane_id),
          metadata: metadata
        })

      nil ->
        {:error, :surface_not_found}
    end
  end

  @doc "Close a preview (soft close, keeps the record for history/audit)."
  def close(%Preview{} = preview) do
    preview
    |> Preview.changeset(%{status: :closed})
    |> Repo.update()
  end

  @doc "Close all open previews for a workspace (agent-first reconcile on mount)."
  def close_all_open(workspace_id) when is_binary(workspace_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      from(p in Preview,
        where: p.workspace_id == ^workspace_id and p.status == :open
      )
      |> Repo.update_all(set: [status: :closed, updated_at: now])

    count
  end

  @doc "List currently open previews for a workspace (for sidebar / state)."
  def list_for_workspace(workspace_id) do
    Repo.all(
      from p in Preview,
        where: p.workspace_id == ^workspace_id and p.status == :open,
        order_by: [asc: p.inserted_at]
    )
  end

  @doc "Fetch the first open preview matching the derived surface/origin key."
  def find_open_for_attrs(workspace_id, attrs) when is_binary(workspace_id) and is_map(attrs) do
    surface_key = Identity.attrs_key(attrs)
    url = Map.get(attrs, :url) || Map.get(attrs, "url")

    # An explicit metadata surface_key is a deliberate identity (e.g. one
    # preview per tmux pane). Match strictly on it with no URL fallback, so two
    # panes can show the same URL as independent previews (mobile + desktop).
    fallback_url = if Identity.explicit_surface_key(attrs), do: nil, else: url

    cond do
      is_binary(surface_key) -> find_open_for_surface_key(workspace_id, surface_key, fallback_url)
      is_binary(url) -> find_open_for_url(workspace_id, url)
      true -> nil
    end
  end

  def find_open_for_attrs(_, _), do: nil

  @doc """
  Returns true for HTTP(S) URLs that can be controlled and shown inside the
  DevIDE cockpit panel.
  """
  def trusted_url?(url), do: Url.trusted_embed?(url)

  def trusted_url?(url, workspace) when is_map(workspace),
    do: Url.trusted_embed?(url, Url.allowed_origins(workspace))

  def trusted_url?(url, allowed_origins) when is_list(allowed_origins),
    do: Url.trusted_embed?(url, allowed_origins)

  @doc "Fetch a single preview by id (scoped to workspace for safety)."
  def get_for_workspace(id, workspace_id) do
    Repo.one(
      from p in Preview,
        where: p.id == ^id and p.workspace_id == ^workspace_id
    )
  end

  @doc """
  Update the URL for an open preview, preserving its existing metadata allowlist.

  `:source_url` records the real site behind a snapshot/served capture (e.g.
  whitehouse.gov when we display `/preview-artifacts/...`). It is stored under
  `metadata["source_url"]` so observers can report the real URL instead of the
  path we serve it from, and cleared when the displayed URL is itself the real
  one (an ordinary embeddable navigation), so it never goes stale.
  """
  def update_url(id, workspace_id, url, opts \\ [])
      when is_binary(workspace_id) and is_binary(url) and is_list(opts) do
    case get_for_workspace(id, workspace_id) do
      %Preview{} = preview ->
        metadata =
          (preview.metadata || %{})
          |> Map.put("display_url", url)
          |> put_source_url(Keyword.get(opts, :source_url))

        preview
        |> Preview.changeset(%{
          url: url,
          title: extract_title_from_url(url),
          metadata: metadata
        })
        |> Repo.update()

      nil ->
        nil
    end
  end

  defp put_source_url(metadata, source_url) when is_binary(source_url) and source_url != "",
    do: Map.put(metadata, "source_url", source_url)

  defp put_source_url(metadata, _source_url), do: Map.delete(metadata, "source_url")

  @doc """
  Resolve a preview for the workspace the human is viewing.

  Falls back to linked manager/folder workspace ids and mirrors the preview
  record into the viewer workspace when needed.
  """
  def get_for_viewer(id, workspace) when is_map(workspace) do
    workspace_id = workspace.id || workspace[:id]

    case get_for_workspace(id, workspace_id) do
      %Preview{} = preview ->
        preview

      nil ->
        mirror_linked_preview(id, workspace)
    end
  end

  defp mirror_linked_preview(id, workspace) do
    workspace_id = workspace.id || workspace[:id]

    allowed_ids = WorkspaceAliases.viewer_ids(workspace_id)

    source =
      Repo.one(
        from p in Preview,
          where: p.id == ^id and p.workspace_id in ^allowed_ids
      )

    case source do
      %Preview{} = source ->
        if WorkspaceAliases.linked?(source.workspace_id, workspace_id) do
          safe_metadata =
            Map.drop(source.metadata || %{}, [
              "allowed_origins",
              "control_url",
              "surface_key"
            ])

          result =
            try do
              find_or_open(workspace, %{
                url: source.url,
                title: source.title,
                mode: source.mode,
                metadata: safe_metadata
              })
            rescue
              e in [Ecto.ConstraintError] ->
                _ = e
                {:conflict, nil}
            end

          case result do
            {:ok, preview} ->
              preview

            {:conflict, _} ->
              find_open_for_attrs(workspace_id, %{url: source.url})

            {:error, %Ecto.Changeset{errors: errors}} ->
              if constraint_error?(errors) do
                find_open_for_attrs(workspace_id, %{url: source.url})
              else
                nil
              end

            _ ->
              nil
          end
        else
          nil
        end

      nil ->
        nil
    end
  end

  defp constraint_error?(errors) do
    Enum.any?(errors, fn
      {_field, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
  end

  @doc false
  def get_for_workspace!(id, workspace_id) do
    case get_for_workspace(id, workspace_id) do
      %Preview{} = preview -> preview
      nil -> raise Ecto.NoResultsError, queryable: Preview
    end
  end

  @doc "Derive a short human title from a URL (host:port)."
  def extract_title_from_url(url) when is_binary(url) do
    uri = URI.parse(url)
    host = uri.host || "preview"
    port = if uri.port in [80, 443], do: "", else: ":#{uri.port}"
    "#{host}#{port}"
  end

  def extract_title_from_url(_), do: "Preview"

  @doc "Stable deduplication key for raw preview URLs."
  def surface_key_for_url(url), do: Identity.url_key(url)

  @doc "Stable deduplication key for a named surface."
  def surface_key_for_surface(surface), do: Identity.surface_key(surface)

  @doc "Preview candidates detected from terminal output."
  def discover_candidates(data), do: DevIDE.Previews.Detector.discover(data)

  @doc "Named preview surfaces from workspace metadata (v3) and terminal hints."
  def discover_surfaces(workspace) when is_map(workspace), do: SurfaceResolver.resolve(workspace)

  @doc "Primary surface for agent-first preview (see `SurfaceResolver.primary_surface/1`)."
  def primary_surface(workspace) when is_map(workspace),
    do: SurfaceResolver.primary_surface(workspace)

  defp normalize_open_attrs(workspace, attrs, workspace_id) do
    allowed_origins = Url.allowed_origins(workspace)

    metadata =
      attrs
      |> Map.get(:metadata, %{})
      |> Map.put_new("allowed_origins", allowed_origins)
      |> put_surface_key(attrs)

    attrs
    |> Map.put(:workspace_id, workspace_id)
    |> Map.put(:metadata, metadata)
    |> Map.put_new(:trusted, trusted_url?(Map.get(attrs, :url), allowed_origins))
  end

  defp put_surface_key(metadata, attrs) do
    case Identity.attrs_key(Map.put(attrs, :metadata, metadata)) do
      key when is_binary(key) and key != "" -> Map.put(metadata, "surface_key", key)
      _ -> metadata
    end
  end

  defp insert_preview(attrs) do
    %Preview{}
    |> Preview.changeset(attrs)
    |> Repo.insert()
  end

  defp find_open_for_surface_key(workspace_id, surface_key, url) do
    if same_url_fallback?(url) do
      Repo.one(
        from p in Preview,
          where: p.workspace_id == ^workspace_id and p.status == :open,
          where: fragment("?->>? = ?", p.metadata, "surface_key", ^surface_key) or p.url == ^url,
          order_by: [asc: p.inserted_at],
          limit: 1
      )
    else
      Repo.one(
        from p in Preview,
          where: p.workspace_id == ^workspace_id and p.status == :open,
          where: fragment("?->>? = ?", p.metadata, "surface_key", ^surface_key),
          order_by: [asc: p.inserted_at],
          limit: 1
      )
    end
  end

  defp find_open_for_url(workspace_id, url) do
    Repo.one(
      from p in Preview,
        where: p.workspace_id == ^workspace_id and p.status == :open and p.url == ^url,
        order_by: [asc: p.inserted_at],
        limit: 1
    )
  end

  defp same_url_fallback?(url), do: is_binary(url) and url != ""
end
