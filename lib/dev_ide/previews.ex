defmodule DevIDE.Previews do
  @moduledoc """
  Preview Broker context.

  Manages browser previews (dev server tabs / in-cockpit iframes) that can be
  spawned from terminal sessions, command output, annotations, or the palette.

  Previews are the surface that makes annotations more powerful (e.g. "the
  error is visible at http://localhost:4000/..." can be turned into a live
  preview pane or tab with audit trail).
  """

  import Ecto.Query

  alias DevIde.Repo
  alias DevIDE.Previews.{Preview, Url}
  alias DevIDE.Audit

  @type preview :: Preview.t()
  @type workspace :: map()

  @doc """
  Open a preview for a workspace.

  `attrs` should include at minimum `:url`. `:mode` (tab | iframe), `:title`,
  `:session_id`, `:pane_id`, and `:metadata` are optional.

  Trusted flag is computed for safety (only local/project-controlled URLs
  are allowed to render as iframes inside the cockpit).
  """
  def open(workspace, attrs) when is_map(workspace) do
    workspace_id = workspace.id || workspace[:id]

    attrs =
      attrs
      |> Map.put(:workspace_id, workspace_id)
      |> Map.put_new(:trusted, trusted_url?(Map.get(attrs, :url)))

    changeset = Preview.changeset(%Preview{}, attrs)

    case Repo.insert(changeset) do
      {:ok, preview} ->
        actor_id = Map.get(attrs, :actor_id) || nil

        Audit.emit!(%{
          action: "preview.opened",
          workspace_id: workspace_id,
          actor_id: actor_id,
          target_type: "preview",
          target_ref: preview.id,
          metadata: %{
            url: preview.url,
            mode: preview.mode,
            trusted: preview.trusted,
            session_id: attrs[:session_id],
            pane_id: attrs[:pane_id]
          }
        })

        {:ok, preview}

      error ->
        error
    end
  end

  @doc "Close a preview (soft close, keeps the record for history/audit)."
  def close(%Preview{} = preview) do
    preview
    |> Preview.changeset(%{status: :closed})
    |> Repo.update()
  end

  @doc "List currently open previews for a workspace (for sidebar / state)."
  def list_for_workspace(workspace_id) do
    Repo.all(
      from p in Preview,
        where: p.workspace_id == ^workspace_id and p.status == :open,
        order_by: [asc: p.inserted_at]
    )
  end

  @doc """
  Returns true for URLs that are safe to embed as iframes inside the DevIDE
  cockpit (localhost dev servers, project-controlled origins, etc.).
  """
  def is_trusted_url?(url), do: trusted_url?(url)

  defp trusted_url?(url), do: Url.trusted_embed?(url)

  @doc "Fetch a single preview by id (scoped to workspace for safety)."
  def get_for_workspace(id, workspace_id) do
    Repo.one(
      from p in Preview,
        where: p.id == ^id and p.workspace_id == ^workspace_id
    )
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

  @doc "Preview candidates detected from terminal output."
  def discover_candidates(data), do: DevIDE.Previews.Detector.discover(data)
end
