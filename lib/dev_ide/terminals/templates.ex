defmodule DevIDE.Terminals.Templates do
  @moduledoc """
  Persistence boundary for workspace-scoped session template exports.

  Saved templates store DevIDE template schema maps produced by
  `DevIDE.Terminals.SessionTemplate.Export`. Version 2 exports can be planned
  and executed by `DevIDE.Terminals.Templates.Executor`.
  """

  import Ecto.Query

  alias DevIDE.Terminals.Templates.Executor
  alias DevIDE.Terminals.Templates.ReconcileExecutor
  alias DevIDE.Terminals.Templates.Reconciler
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
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Row{} = row <- Repo.get_by(Row, id: uuid, workspace_id: workspace_id) do
      {:ok, to_map(row)}
    else
      _ -> {:error, :not_found}
    end
  end

  @spec delete(String.t(), String.t()) :: :ok | {:error, :not_found}
  def delete(workspace_id, id) when is_binary(workspace_id) and is_binary(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Row{} = row <- Repo.get_by(Row, id: uuid, workspace_id: workspace_id),
         {:ok, _row} <- Repo.delete(row) do
      :ok
    else
      _ -> {:error, :not_found}
    end
  end

  @spec apply_supported?(saved()) :: boolean()
  def apply_supported?(saved) when is_map(saved) do
    saved.schema_version == 2 and get_in(saved.body || %{}, ["version"]) == 2
  end

  @spec dry_run(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def dry_run(workspace_id, id, opts \\ []) do
    with {:ok, saved} <- get(workspace_id, id),
         true <- apply_supported?(saved) do
      Executor.dry_run(saved, opts)
    else
      false -> {:error, :unsupported_template}
      {:error, :not_found} -> {:error, :template_not_found}
    end
  end

  @spec execute(String.t(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute(workspace_id, session, id, opts \\ []) when is_binary(session) do
    with {:ok, saved} <- get(workspace_id, id),
         true <- apply_supported?(saved) do
      Executor.execute(session, saved, opts)
    else
      false -> {:error, :unsupported_template}
      {:error, :not_found} -> {:error, :template_not_found}
    end
  end

  @spec execute_reconcile(String.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def execute_reconcile(workspace_id, session, id, topology, opts \\ [])
      when is_binary(session) and is_map(topology) do
    with {:ok, saved} <- get(workspace_id, id),
         true <- apply_supported?(saved),
         {:ok, diff} <- Reconciler.diff(topology, saved, opts),
         {:ok, execution} <- ReconcileExecutor.execute(session, diff, opts) do
      {:ok, %{diff: diff, execution: execution}}
    else
      false -> {:error, :unsupported_template}
      {:error, :not_found} -> {:error, :template_not_found}
      {:error, _reason} = error -> error
    end
  end

  @spec diff(String.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def diff(workspace_id, id, topology, opts \\ []) when is_map(topology) do
    with {:ok, saved} <- get(workspace_id, id),
         true <- apply_supported?(saved) do
      Reconciler.diff(topology, saved, opts)
    else
      false -> {:error, :unsupported_template}
      {:error, :not_found} -> {:error, :template_not_found}
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
