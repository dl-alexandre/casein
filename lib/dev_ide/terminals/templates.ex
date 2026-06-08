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
    with {:ok, row} <- get_row(workspace_id, id) do
      {:ok, to_map(row)}
    end
  end

  @spec update(String.t(), String.t(), map(), keyword()) ::
          {:ok, saved()} | {:error, :not_found | :name_required | :name_taken}
  def update(workspace_id, id, attrs, opts \\ [])
      when is_binary(workspace_id) and is_binary(id) and is_map(attrs) do
    dry_run? = Keyword.get(opts, :dry_run, false)

    with {:ok, row} <- get_row(workspace_id, id),
         {:ok, updates} <- update_attrs(attrs),
         :ok <- validate_unique_name(row, updates) do
      if dry_run? do
        {:ok,
         row
         |> to_map()
         |> Map.merge(updates)
         |> Map.put(:updated_at, DateTime.utc_now())}
      else
        row
        |> Ecto.Changeset.change(updates)
        |> Repo.update()
        |> case do
          {:ok, row} -> {:ok, to_map(row)}
          {:error, _changeset} -> {:error, :name_required}
        end
      end
    end
  end

  @spec duplicate(String.t(), String.t(), map(), keyword()) ::
          {:ok, saved()} | {:error, :not_found | :name_required | :name_taken}
  def duplicate(workspace_id, id, attrs \\ %{}, opts \\ [])
      when is_binary(workspace_id) and is_binary(id) and is_map(attrs) do
    dry_run? = Keyword.get(opts, :dry_run, false)

    with {:ok, row} <- get_row(workspace_id, id),
         {:ok, duplicate_attrs} <- duplicate_attrs(row, attrs),
         :ok <- validate_unique_template_name(row.workspace_id, duplicate_attrs.name) do
      now = DateTime.utc_now()

      if dry_run? do
        {:ok,
         %{
           id: nil,
           workspace_id: row.workspace_id,
           name: duplicate_attrs.name,
           description: duplicate_attrs.description,
           body: row.body || %{},
           source_session: row.source_session,
           schema_version: row.schema_version,
           inserted_at: now,
           updated_at: now
         }}
      else
        %Row{}
        |> Ecto.Changeset.change(%{
          workspace_id: row.workspace_id,
          name: duplicate_attrs.name,
          description: duplicate_attrs.description,
          body: row.body || %{},
          source_session: row.source_session,
          schema_version: row.schema_version
        })
        |> Repo.insert()
        |> case do
          {:ok, row} -> {:ok, to_map(row)}
          {:error, _changeset} -> {:error, :name_required}
        end
      end
    end
  end

  @spec delete(String.t(), String.t()) :: :ok | {:error, :not_found}
  def delete(workspace_id, id) when is_binary(workspace_id) and is_binary(id) do
    with {:ok, row} <- get_row(workspace_id, id),
         {:ok, _row} <- Repo.delete(row) do
      :ok
    else
      {:error, :not_found} -> {:error, :not_found}
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

  defp get_row(workspace_id, id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Row{} = row <- Repo.get_by(Row, id: uuid, workspace_id: workspace_id) do
      {:ok, row}
    else
      _ -> {:error, :not_found}
    end
  end

  defp update_attrs(attrs) do
    [:name, :description]
    |> Enum.reduce_while({:ok, %{}}, fn field, {:ok, acc} ->
      case update_attr(attrs, field) do
        :skip ->
          {:cont, {:ok, acc}}

        {:ok, value} ->
          case normalize_update_attr(field, value) do
            {:ok, normalized} -> {:cont, {:ok, Map.put(acc, field, normalized)}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    end)
  end

  defp update_attr(attrs, field) do
    string_field = Atom.to_string(field)

    cond do
      Map.has_key?(attrs, field) -> {:ok, Map.get(attrs, field)}
      Map.has_key?(attrs, string_field) -> {:ok, Map.get(attrs, string_field)}
      true -> :skip
    end
  end

  defp normalize_update_attr(:name, value) do
    case value |> to_string() |> String.trim() do
      "" -> {:error, :name_required}
      name -> {:ok, name}
    end
  end

  defp normalize_update_attr(:description, nil), do: {:ok, nil}

  defp normalize_update_attr(:description, value) do
    case value |> to_string() |> String.trim() do
      "" -> {:ok, nil}
      description -> {:ok, description}
    end
  end

  defp validate_unique_name(%Row{} = row, %{name: name}) when name != row.name do
    validate_unique_template_name(row.workspace_id, name, row.id)
  end

  defp validate_unique_name(_row, _updates), do: :ok

  defp validate_unique_template_name(workspace_id, name, exclude_id \\ nil) do
    if name_taken?(workspace_id, name, exclude_id), do: {:error, :name_taken}, else: :ok
  end

  defp name_taken?(workspace_id, name, exclude_id) do
    Row
    |> where([r], r.workspace_id == ^workspace_id)
    |> where([r], r.name == ^name)
    |> maybe_exclude_id(exclude_id)
    |> Repo.exists?()
  end

  defp maybe_exclude_id(query, nil), do: query
  defp maybe_exclude_id(query, id), do: where(query, [r], r.id != ^id)

  defp duplicate_attrs(%Row{} = row, attrs) do
    with {:ok, name} <- duplicate_name(row, attrs),
         {:ok, description} <- duplicate_description(row, attrs) do
      {:ok, %{name: name, description: description}}
    end
  end

  defp duplicate_name(%Row{} = row, attrs) do
    case update_attr(attrs, :name) do
      :skip -> {:ok, unique_copy_name(row.workspace_id, row.name)}
      {:ok, value} -> normalize_update_attr(:name, value)
    end
  end

  defp duplicate_description(%Row{} = row, attrs) do
    case update_attr(attrs, :description) do
      :skip -> {:ok, row.description}
      {:ok, value} -> normalize_update_attr(:description, value)
    end
  end

  defp unique_copy_name(workspace_id, name) do
    base = "#{name} (copy)"

    ([base] ++ Enum.map(2..100, &"#{name} (copy #{&1})"))
    |> Enum.find(&(not name_taken?(workspace_id, &1, nil)))
    |> case do
      nil -> "#{name} (copy #{System.unique_integer([:positive])})"
      copy_name -> copy_name
    end
  end
end
