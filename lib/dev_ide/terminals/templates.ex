defmodule DevIDE.Terminals.Templates do
  @moduledoc """
  Persistence boundary for workspace-scoped session template exports.

  Saved templates store DevIDE template schema maps produced by
  `DevIDE.Terminals.SessionTemplate.Export`. M3.1 deliberately keeps them as
  saved/exported artifacts only; v2 apply is a later executor concern.
  """

  import Ecto.Query

  alias DevIde.Repo

  defmodule Row do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}
    schema "saved_templates" do
      field :workspace_id, :string
      field :name, :string
      field :description, :string
      field :body, :map, default: %{}
      field :source_session, :string
      field :schema_version, :integer, default: 2
      timestamps(type: :utc_datetime_usec)
    end
  end

  @type saved :: %{
          id: String.t(),
          workspace_id: String.t(),
          name: String.t(),
          description: String.t() | nil,
          body: map(),
          source_session: String.t() | nil,
          schema_version: integer(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @spec save(map()) :: {:ok, saved()} | {:error, Ecto.Changeset.t()}
  def save(attrs) when is_map(attrs) do
    %Row{}
    |> Ecto.Changeset.cast(attrs, [
      :workspace_id,
      :name,
      :description,
      :body,
      :source_session,
      :schema_version
    ])
    |> Ecto.Changeset.validate_required([:workspace_id, :name, :body, :schema_version])
    |> Ecto.Changeset.validate_length(:name, min: 1, max: 255)
    |> Ecto.Changeset.validate_number(:schema_version, greater_than: 0)
    |> Repo.insert()
    |> case do
      {:ok, row} -> {:ok, to_map(row)}
      {:error, _changeset} = error -> error
    end
  end

  @spec list_for_workspace(String.t()) :: [saved()]
  def list_for_workspace(workspace_id) when is_binary(workspace_id) do
    Row
    |> where([r], r.workspace_id == ^workspace_id)
    |> order_by([r], desc: r.inserted_at)
    |> Repo.all()
    |> Enum.map(&to_map/1)
  end

  @spec get(String.t(), String.t()) :: {:ok, saved()} | {:error, :not_found}
  def get(workspace_id, id) when is_binary(workspace_id) and is_binary(id) do
    case Repo.get_by(Row, id: id, workspace_id: workspace_id) do
      nil -> {:error, :not_found}
      row -> {:ok, to_map(row)}
    end
  end

  defp to_map(%Row{} = row) do
    %{
      id: row.id,
      workspace_id: row.workspace_id,
      name: row.name,
      description: row.description,
      body: row.body || %{},
      source_session: row.source_session,
      schema_version: row.schema_version,
      inserted_at: row.inserted_at,
      updated_at: row.updated_at
    }
  end
end
