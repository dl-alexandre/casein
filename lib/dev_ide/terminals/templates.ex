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
      field :tags, DevIDE.EctoTypes.StringList, default: []
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
          tags: [String.t()],
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @spec save(map()) :: {:ok, saved()} | {:error, Ecto.Changeset.t()}
  def save(attrs) when is_map(attrs) do
    attrs = normalize_attrs_tags(attrs)

    %Row{}
    |> Ecto.Changeset.cast(attrs, [
      :workspace_id,
      :name,
      :description,
      :body,
      :source_session,
      :schema_version,
      :tags
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

  @spec list_for_workspace(String.t(), keyword()) :: [saved()]
  def list_for_workspace(workspace_id, opts \\ []) when is_binary(workspace_id) do
    tags = Keyword.get(opts, :tags)

    Row
    |> where([r], r.workspace_id == ^workspace_id)
    |> maybe_filter_tags(tags)
    |> order_by([r], desc: r.inserted_at)
    |> Repo.all()
    |> maybe_filter_tag_rows(tags)
    |> Enum.map(&to_map/1)
  end

  @spec get(String.t(), String.t()) :: {:ok, saved()} | {:error, :not_found}
  def get(workspace_id, id) when is_binary(workspace_id) and is_binary(id) do
    with {:ok, row} <- get_row(workspace_id, id) do
      {:ok, to_map(row)}
    end
  end

  @spec get_by_id(String.t()) :: {:ok, saved()} | {:error, :not_found}
  def get_by_id(id) when is_binary(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Row{} = row <- Repo.get(Row, uuid) do
      {:ok, to_map(row)}
    else
      _ -> {:error, :not_found}
    end
  end

  @spec update(String.t(), String.t(), map(), keyword()) ::
          {:ok, saved()} | {:error, :not_found | :name_required | :name_taken | :invalid_tags}
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
          {:ok, saved()} | {:error, :not_found | :name_required | :name_taken | :invalid_tags}
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
           tags: duplicate_attrs.tags,
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
          schema_version: row.schema_version,
          tags: duplicate_attrs.tags
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
      Executor.execute(session, saved, Keyword.put(opts, :workspace_id, workspace_id))
    else
      false -> {:error, :unsupported_template}
      {:error, :not_found} -> {:error, :template_not_found}
    end
  end

  @spec execute_reconcile(String.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def execute_reconcile(workspace_id, session, id, topology, opts \\ [])
      when is_binary(session) and is_map(topology) do
    opts = Keyword.put(opts, :workspace_id, workspace_id)

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
      tags: row.tags || [],
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
    [:name, :description, :tags]
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

  defp normalize_update_attr(:tags, value), do: normalize_tags(value)

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
         {:ok, description} <- duplicate_description(row, attrs),
         {:ok, tags} <- duplicate_tags(row, attrs) do
      {:ok, %{name: name, description: description, tags: tags}}
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

  defp duplicate_tags(%Row{} = row, attrs) do
    case update_attr(attrs, :tags) do
      :skip -> {:ok, row.tags || []}
      {:ok, value} -> normalize_tags(value)
    end
  end

  defp unique_copy_name(workspace_id, name) do
    candidates = ["#{name} (copy)"] ++ Enum.map(2..100, &"#{name} (copy #{&1})")

    taken =
      Row
      |> where([r], r.workspace_id == ^workspace_id)
      |> where([r], r.name in ^candidates)
      |> select([r], r.name)
      |> Repo.all()
      |> MapSet.new()

    Enum.find(candidates, &(not MapSet.member?(taken, &1))) ||
      "#{name} (copy #{System.unique_integer([:positive])})"
  end

  defp normalize_attrs_tags(attrs) do
    case update_attr(attrs, :tags) do
      :skip ->
        attrs

      {:ok, value} ->
        case normalize_tags(value) do
          {:ok, tags} -> Map.put(attrs, update_attr_key(attrs, :tags), tags)
          {:error, _reason} -> attrs
        end
    end
  end

  defp update_attr_key(attrs, field) do
    string_field = Atom.to_string(field)

    cond do
      Map.has_key?(attrs, field) -> field
      Map.has_key?(attrs, string_field) -> string_field
      true -> field
    end
  end

  defp normalize_tags(nil), do: {:ok, []}

  defp normalize_tags(value) when is_binary(value) do
    value
    |> String.split([",", "\n"], trim: true)
    |> normalize_tags()
  end

  defp normalize_tags(values) when is_list(values) do
    tags =
      values
      |> Enum.map(&normalize_tag/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    {:ok, tags}
  end

  defp normalize_tags(_value), do: {:error, :invalid_tags}

  defp normalize_tag(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/\s+/, "-")
  end

  defp maybe_filter_tags(query, nil), do: query
  defp maybe_filter_tags(query, []), do: query
  defp maybe_filter_tags(query, ""), do: query

  if DevIDE.Repo.Adapter.sqlite?() do
    defp maybe_filter_tags(query, _tags), do: query

    defp maybe_filter_tag_rows(rows, tags) do
      case normalize_tags(tags) do
        {:ok, []} ->
          rows

        {:ok, normalized_tags} ->
          required = MapSet.new(normalized_tags)

          Enum.filter(rows, fn row ->
            row_tags = MapSet.new(row.tags || [])
            MapSet.subset?(required, row_tags)
          end)

        {:error, _reason} ->
          rows
      end
    end
  else
    defp maybe_filter_tags(query, tags) do
      case normalize_tags(tags) do
        {:ok, []} ->
          query

        {:ok, normalized_tags} ->
          where(query, [r], fragment("? @> ?::text[]", r.tags, ^normalized_tags))

        {:error, _reason} ->
          query
      end
    end

    defp maybe_filter_tag_rows(rows, _tags), do: rows
  end
end
