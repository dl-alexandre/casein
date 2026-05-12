defmodule DevIDE.Assignments.EventStore.RepoAdapter do
  @moduledoc """
  Postgres-backed adapter for `DevIDE.Assignments.EventStore`.

  Persists events to the `assignment_events` table and replays from it.
  Sequence assignment is deterministic (max existing + 1) per assignment.

  Payloads are stored as maps with an explicit version field for
  future-proofing migrations.
  """

  @behaviour DevIDE.Assignments.EventStore

  alias DevIDE.Assignments.Event
  alias DevIDE.Assignments.EventRow
  alias DevIde.Repo
  import Ecto.Query

  @payload_version 1

  @impl DevIDE.Assignments.EventStore
  def append(%Event{} = event) do
    assignment_id = event.assignment_id

    max_sequence =
      from(r in EventRow,
        where: r.assignment_id == ^assignment_id,
        select: max(r.sequence)
      )
      |> Repo.one() || 0

    row =
      %EventRow{}
      |> EventRow.changeset(%{
        id: event.id,
        assignment_id: assignment_id,
        sequence: max_sequence + 1,
        type: Atom.to_string(event.type),
        actor: event.actor,
        payload: normalize_payload(event.payload),
        occurred_at: event.occurred_at
      })

    case Repo.insert(row) do
      {:ok, inserted} ->
        {:ok, to_event(inserted)}

      {:error, changeset} ->
        {:error, changeset_error(changeset)}
    end
  end

  @impl DevIDE.Assignments.EventStore
  def events_for(assignment_id) when is_binary(assignment_id) do
    from(r in EventRow,
      where: r.assignment_id == ^assignment_id,
      order_by: [asc: r.sequence]
    )
    |> Repo.all()
    |> Enum.map(&to_event/1)
  end

  @impl DevIDE.Assignments.EventStore
  def list_events(_opts \\ []) do
    from(r in EventRow,
      order_by: [asc: r.assignment_id, asc: r.sequence]
    )
    |> Repo.all()
    |> Enum.map(&to_event/1)
  end

  @impl DevIDE.Assignments.EventStore
  def clear do
    {_count, _} = Repo.delete_all(EventRow)
    :ok
  end

  ## Internal

  defp normalize_payload(payload) when is_map(payload) do
    Map.put(payload, "_version", @payload_version)
  end

  defp normalize_payload(_), do: %{"_version" => @payload_version}

  defp to_event(%EventRow{} = row) do
    %Event{
      id: row.id,
      assignment_id: row.assignment_id,
      sequence: row.sequence,
      type: String.to_existing_atom(row.type),
      actor: row.actor,
      payload: Map.drop(row.payload, ["_version"]),
      occurred_at: row.occurred_at
    }
  rescue
    ArgumentError ->
      %Event{
        id: row.id,
        assignment_id: row.assignment_id,
        sequence: row.sequence,
        type: :unknown,
        actor: row.actor,
        payload: Map.drop(row.payload, ["_version"]),
        occurred_at: row.occurred_at
      }
  end

  defp changeset_error(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r/%{(\w+)}/, msg, fn _, key ->
        to_string(Keyword.get(opts, String.to_existing_atom(key), key))
      end)
    end)
  end
end
