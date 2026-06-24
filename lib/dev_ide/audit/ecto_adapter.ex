defmodule DevIDE.Audit.EctoAdapter do
  @moduledoc """
  Postgres-backed adapter for `DevIDE.Audit`.

  Maps `DevIDE.Audit.Event` to/from a private Ecto schema, scoped to this
  module so callers (LiveViews, Policy, Audit) only ever see the domain
  struct. Atoms in `decision`/`reason` are stored as strings; metadata is
  a JSON map.
  """

  @behaviour DevIDE.Audit.Adapter

  alias DevIDE.Audit.Event
  alias DevIde.Repo
  import Ecto.Query

  defmodule Row do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: false}
    schema "audit_events" do
      field :workspace_id, :string
      field :actor_id, :string
      field :action, :string
      field :target_type, :string
      field :target_ref, :string
      field :decision, :string
      field :reason, :string
      field :metadata, :map, default: %{}
      field :inserted_at, :utc_datetime_usec
    end
  end

  @max_metadata_bytes 32 * 1024

  ## Public API

  @impl true
  def record(%Event{} = event) do
    case Repo.insert(struct(Row, to_row(event))) do
      {:ok, _row} -> :ok
      {:error, _} = err -> err
    end
  end

  @impl true
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    Row
    |> order_by([r], desc: r.inserted_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(&to_event/1)
  end

  @impl true
  def recent_for(workspace_id, n) do
    Row
    |> where([r], r.workspace_id == ^workspace_id)
    |> order_by([r], desc: r.inserted_at)
    |> limit(^n)
    |> Repo.all()
    |> Enum.map(&to_event/1)
  end

  @impl true
  def recent_with_action_prefix(workspace_id, action_prefix, n)
      when is_binary(action_prefix) do
    pattern = like_prefix(action_prefix)

    Row
    |> where([r], r.workspace_id == ^workspace_id)
    |> where([r], like(r.action, ^pattern))
    |> order_by([r], desc: r.inserted_at)
    |> limit(^n)
    |> Repo.all()
    |> Enum.map(&to_event/1)
  end

  @impl true
  def clear do
    Repo.delete_all(Row)
    :ok
  end

  # Escape LIKE metacharacters so a prefix is matched literally, then append
  # the trailing wildcard. `\` is the default ESCAPE character in Postgres LIKE.
  defp like_prefix(prefix) do
    escaped =
      prefix
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

    escaped <> "%"
  end

  ## Mappers

  defp to_row(%Event{} = e) do
    %{
      id: e.id,
      workspace_id: e.workspace_id,
      actor_id: e.actor_id,
      action: e.action,
      target_type: e.target_type,
      target_ref: e.target_ref,
      decision: e.decision && Atom.to_string(e.decision),
      reason: e.reason && Atom.to_string(e.reason),
      metadata: normalize_metadata(e.metadata),
      inserted_at: e.inserted_at
    }
  end

  defp normalize_metadata(nil), do: %{}

  defp normalize_metadata(map) when is_map(map) do
    encoded = Jason.encode!(map)

    if byte_size(encoded) > @max_metadata_bytes do
      %{"truncated" => true}
    else
      Jason.decode!(encoded)
    end
  end

  defp normalize_metadata(_), do: %{}

  defp to_event(%Row{} = r) do
    %Event{
      id: r.id,
      workspace_id: r.workspace_id,
      actor_id: r.actor_id,
      action: r.action,
      target_type: r.target_type,
      target_ref: r.target_ref,
      decision: r.decision && safe_to_atom(r.decision),
      reason: r.reason && safe_to_atom(r.reason),
      metadata: r.metadata || %{},
      inserted_at: r.inserted_at
    }
  end

  defp safe_to_atom(s) when is_binary(s) do
    try do
      String.to_existing_atom(s)
    rescue
      ArgumentError -> nil
    end
  end
end
