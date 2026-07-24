defmodule Casein.Annotations do
  @moduledoc """
  Workspace annotations linking terminal, file, and preview context.

  This context is intentionally storage-first and UI-agnostic. LiveViews can
  subscribe to `workspace:<id>` PubSub messages, while agents can use the same
  APIs as tool backends for listing and proposing annotations.
  """

  import Ecto.Query

  alias Casein.Annotations.Annotation
  alias Casein.Audit
  alias Casein.Repo

  @topic_prefix "workspace:"
  @attr_key_map %{
    "content" => :content,
    "author_type" => :author_type,
    "visibility" => :visibility,
    "approval_state" => :approval_state,
    "workspace_id" => :workspace_id,
    "session_id" => :session_id,
    "pane_id" => :pane_id,
    "preview_id" => :preview_id,
    "terminal_range" => :terminal_range,
    "file_path" => :file_path,
    "file_range" => :file_range,
    "linked_entities" => :linked_entities,
    "metadata" => :metadata,
    "actor_id" => :actor_id
  }
  @attr_atom_keys @attr_key_map |> Map.values() |> MapSet.new()

  @type workspace_ref :: String.t() | %{id: String.t()} | %{id: atom()}

  @spec create(workspace_ref(), map()) :: {:ok, Annotation.t()} | {:error, Ecto.Changeset.t()}
  def create(workspace, attrs) when is_map(attrs) do
    workspace_id = workspace_id!(workspace)
    attrs = attrs |> normalize_attrs() |> Map.put(:workspace_id, workspace_id)

    %Annotation{}
    |> Annotation.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, annotation} ->
        audit(annotation, attrs, "annotation.created")
        broadcast(annotation.workspace_id, {:annotation_created, annotation})
        {:ok, annotation}

      {:error, _changeset} = error ->
        error
    end
  end

  @spec propose_from_agent(workspace_ref(), map()) ::
          {:ok, Annotation.t()} | {:error, Ecto.Changeset.t()}
  def propose_from_agent(workspace, attrs) when is_map(attrs) do
    attrs
    |> normalize_attrs()
    |> Map.put_new(:approval_state, :pending)
    |> Map.put_new(:visibility, :shared)
    |> then(&create(workspace, &1))
  end

  @spec list_for_workspace(String.t(), keyword()) :: [Annotation.t()]
  def list_for_workspace(workspace_id, opts \\ []) when is_binary(workspace_id) do
    limit = Keyword.get(opts, :limit, 100)

    Annotation
    |> where([a], a.workspace_id == ^workspace_id)
    |> filter_by(:preview_id, Keyword.get(opts, :preview_id))
    |> filter_by(:session_id, Keyword.get(opts, :session_id))
    |> filter_by(:pane_id, Keyword.get(opts, :pane_id))
    |> filter_by(:file_path, Keyword.get(opts, :file_path))
    |> filter_by(:approval_state, Keyword.get(opts, :approval_state))
    |> order_by([a], desc: a.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @spec get!(String.t()) :: Annotation.t()
  def get!(id) when is_binary(id), do: Repo.get!(Annotation, id)

  @spec get(String.t()) :: {:ok, Annotation.t()} | {:error, :not_found}
  def get(id) when is_binary(id) do
    case Repo.get(Annotation, id) do
      %Annotation{} = annotation -> {:ok, annotation}
      nil -> {:error, :not_found}
    end
  end

  @spec attach_to_preview(Annotation.t(), String.t() | %{id: String.t()}) ::
          {:ok, Annotation.t()} | {:error, Ecto.Changeset.t()}
  def attach_to_preview(%Annotation{} = annotation, preview_or_id) do
    preview_id = preview_id!(preview_or_id)
    update_annotation(annotation, %{preview_id: preview_id}, "annotation.preview_attached")
  end

  @spec approve(Annotation.t(), map()) :: {:ok, Annotation.t()} | {:error, Ecto.Changeset.t()}
  def approve(%Annotation{} = annotation, attrs \\ %{}) do
    update_annotation(
      annotation,
      Map.put(normalize_attrs(attrs), :approval_state, :approved),
      "annotation.approved"
    )
  end

  @spec reject(Annotation.t(), map()) :: {:ok, Annotation.t()} | {:error, Ecto.Changeset.t()}
  def reject(%Annotation{} = annotation, attrs \\ %{}) do
    update_annotation(
      annotation,
      Map.put(normalize_attrs(attrs), :approval_state, :rejected),
      "annotation.rejected"
    )
  end

  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(workspace_id) when is_binary(workspace_id) do
    Phoenix.PubSub.subscribe(Casein.PubSub, topic(workspace_id))
  end

  defp update_annotation(%Annotation{} = annotation, attrs, action) do
    attrs = normalize_attrs(attrs)

    annotation
    |> Annotation.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, annotation} ->
        audit(annotation, attrs, action)
        broadcast(annotation.workspace_id, {:annotation_updated, annotation})
        {:ok, annotation}

      {:error, _changeset} = error ->
        error
    end
  end

  defp filter_by(query, _field, nil), do: query

  defp filter_by(query, field, value) do
    where(query, [a], field(a, ^field) == ^value)
  end

  defp audit(%Annotation{} = annotation, attrs, action) do
    Audit.emit!(%{
      action: action,
      workspace_id: annotation.workspace_id,
      actor_id: actor_id(attrs),
      target_type: "annotation",
      target_ref: annotation.id,
      metadata: %{
        "annotation_id" => annotation.id,
        "preview_id" => annotation.preview_id,
        "session_id" => annotation.session_id,
        "pane_id" => annotation.pane_id,
        "file_path" => annotation.file_path,
        "author_type" => to_string(annotation.author_type),
        "visibility" => to_string(annotation.visibility),
        "approval_state" => to_string(annotation.approval_state)
      }
    })
  end

  defp broadcast(workspace_id, message) do
    Phoenix.PubSub.broadcast(Casein.PubSub, topic(workspace_id), message)
  end

  defp topic(workspace_id), do: @topic_prefix <> workspace_id

  defp normalize_attrs(attrs) when is_map(attrs) do
    attrs
    |> Enum.reduce(%{}, fn
      {key, value}, acc when is_binary(key) ->
        case Map.fetch(@attr_key_map, key) do
          {:ok, atom_key} -> Map.put(acc, atom_key, value)
          :error -> acc
        end

      {key, value}, acc when is_atom(key) ->
        if MapSet.member?(@attr_atom_keys, key), do: Map.put(acc, key, value), else: acc

      _pair, acc ->
        acc
    end)
  end

  defp workspace_id!(workspace_id) when is_binary(workspace_id), do: workspace_id
  defp workspace_id!(%{id: id}) when is_binary(id), do: id
  defp workspace_id!(%{id: id}) when is_atom(id), do: Atom.to_string(id)

  defp preview_id!(preview_id) when is_binary(preview_id), do: preview_id
  defp preview_id!(%{id: id}) when is_binary(id), do: id

  defp actor_id(%{actor_id: actor_id}) when is_binary(actor_id), do: actor_id
  defp actor_id(%{"actor_id" => actor_id}) when is_binary(actor_id), do: actor_id
  defp actor_id(_), do: nil
end
