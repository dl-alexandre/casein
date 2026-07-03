defmodule DevIDE.Workspaces.State.EctoAdapter do
  @moduledoc "Postgres-backed adapter for `DevIDE.Workspaces.State`."

  @behaviour DevIDE.Workspaces.State.Adapter

  alias DevIDE.Workspaces.State.WorkspaceRecord
  alias DevIde.Repo
  import Ecto.Query

  defmodule Row do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}
    schema "workspace_records" do
      field :external_id, :string
      field :name, :string
      field :host_path, :string
      field :status, :string
      field :mode, :string
      field :db_isolation, :string
      field :db_isolation_source, :string
      field :db_isolation_summary, :string
      field :db_isolation_detected_at, :utc_datetime_usec
      field :manager_payload, :map, default: %{}
      field :last_seen_at, :utc_datetime_usec
      field :agent_write_unlocked_until, :utc_datetime_usec
      field :agent_write_unlocked_by, :string
      field :agent_write_unlock_granted_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end
  end

  @impl true
  def upsert(%WorkspaceRecord{} = r) do
    attrs = Map.from_struct(r) |> Map.drop([:id, :inserted_at, :updated_at])

    %Row{}
    |> Ecto.Changeset.change(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: :external_id,
      returning: true
    )
    |> case do
      {:ok, row} -> {:ok, to_record(row)}
      {:error, _} = err -> err
    end
  end

  @impl true
  def upsert_all([]), do: {:ok, []}

  def upsert_all(records) when is_list(records) do
    now = DateTime.utc_now()

    entries =
      Enum.map(records, fn %WorkspaceRecord{} = r ->
        r
        |> Map.from_struct()
        |> Map.put(:id, r.id || Ecto.UUID.generate())
        |> Map.put(:inserted_at, r.inserted_at || now)
        |> Map.put(:updated_at, now)
      end)

    {_count, rows} =
      Repo.insert_all(Row, entries,
        on_conflict: {:replace_all_except, [:id, :inserted_at]},
        conflict_target: :external_id,
        returning: true
      )

    {:ok, Enum.map(rows, &to_record/1)}
  end

  @impl true
  def get(external_id) do
    case Repo.get_by(Row, external_id: external_id) do
      nil -> :error
      row -> {:ok, to_record(row)}
    end
  end

  @impl true
  def get_many(external_ids) when is_list(external_ids) do
    Row
    |> where([r], r.external_id in ^external_ids)
    |> Repo.all()
    |> Map.new(fn row -> {row.external_id, to_record(row)} end)
  end

  @impl true
  def records_for_host_paths([]), do: %{}

  def records_for_host_paths(host_paths) when is_list(host_paths) do
    Row
    |> where([r], r.host_path in ^host_paths)
    |> Repo.all()
    |> Enum.group_by(& &1.host_path)
    |> Map.new(fn {path, rows} ->
      {path, rows |> Enum.map(&to_record/1) |> WorkspaceRecord.preferred()}
    end)
  end

  @impl true
  def list do
    Row
    |> order_by([r], asc: r.name)
    |> Repo.all()
    |> Enum.map(&to_record/1)
  end

  @impl true
  def delete(external_id) do
    case Repo.get_by(Row, external_id: external_id) do
      nil ->
        :ok

      row ->
        Repo.delete(row)
        |> case do
          {:ok, _} -> :ok
          {:error, _} = err -> err
        end
    end
  end

  defp to_record(%Row{} = r) do
    %WorkspaceRecord{
      id: r.id,
      external_id: r.external_id,
      name: r.name,
      host_path: r.host_path,
      status: r.status,
      mode: r.mode,
      db_isolation: r.db_isolation,
      db_isolation_source: r.db_isolation_source,
      db_isolation_summary: r.db_isolation_summary,
      db_isolation_detected_at: r.db_isolation_detected_at,
      manager_payload: r.manager_payload || %{},
      last_seen_at: r.last_seen_at,
      agent_write_unlocked_until: r.agent_write_unlocked_until,
      agent_write_unlocked_by: r.agent_write_unlocked_by,
      agent_write_unlock_granted_at: r.agent_write_unlock_granted_at,
      inserted_at: r.inserted_at,
      updated_at: r.updated_at
    }
  end
end
