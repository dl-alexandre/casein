defmodule Casein.Inspectors.Run do
  @moduledoc """
  One-shot intent to surface a run ledger viewport to a connected cockpit viewer.

  A run inspector is a viewport over the existing ledger — not a durable pane
  handle. Agents declare **what** to show (optional run id); Casein owns
  placement. If nobody is watching the workspace the call is a no-op (do not
  queue, retry, or persist).

  Surfacing goes through `Casein.Cockpit.Inspectors.request_open/2` (epic #689 /
  #694): mounted cockpits receive `{:inspector_open, attrs}` and open a
  LiveView-owned inspector (or fall back to the full-area `run` tab).
  """

  alias Casein.Cockpit.Inspectors

  @viewer_registry Casein.Inspectors.Run.ViewerRegistry

  @type intent :: %{
          optional(:run_id) => String.t() | nil,
          optional(:actor_id) => String.t() | nil,
          optional(:request_id) => String.t()
        }

  @doc """
  Register the calling process as a watching cockpit viewer.

  Uses a duplicate Registry so presence is process-linked: when the LiveView
  exits the registration vanishes with no explicit unregister. Required so
  `surface/2` can distinguish "nobody watching" from "broadcast delivered".
  """
  @spec register_viewer(String.t()) :: :ok | {:error, term()}
  def register_viewer(workspace_id) when is_binary(workspace_id) and workspace_id != "" do
    case Registry.register(@viewer_registry, workspace_id, true) do
      {:ok, _pid} -> :ok
      {:error, {:already_registered, _}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def register_viewer(_), do: {:error, :workspace_id_required}

  @doc "True when at least one cockpit LiveView is registered for the workspace."
  @spec viewer_present?(String.t()) :: boolean()
  def viewer_present?(workspace_id) when is_binary(workspace_id) and workspace_id != "" do
    match?([_ | _], Registry.lookup(@viewer_registry, workspace_id))
  end

  def viewer_present?(_), do: false

  @doc """
  Surface a run inspector intent to connected viewers.

  Returns `{:ok, %{status: "surfaced" | "no_viewer", ...}}`. Never queues when
  idle — a viewport with no watcher is correctly a no-op.
  """
  @spec surface(String.t(), intent()) :: {:ok, map()} | {:error, term()}
  def surface(workspace_id, intent \\ %{})

  def surface(workspace_id, intent)
      when is_binary(workspace_id) and workspace_id != "" and is_map(intent) do
    request_id = intent_request_id(intent)
    run_id = intent_run_id(intent)

    if viewer_present?(workspace_id) do
      attrs =
        %{kind: :run, id: "insp-run", title: run_title(run_id), run_id: run_id}
        |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
        |> Map.new()

      :ok = Inspectors.request_open(workspace_id, attrs)

      {:ok,
       %{
         status: "surfaced",
         workspace_id: workspace_id,
         run_id: run_id,
         request_id: request_id
       }
       |> compact()}
    else
      {:ok,
       %{
         status: "no_viewer",
         workspace_id: workspace_id,
         run_id: run_id,
         request_id: request_id
       }
       |> compact()}
    end
  end

  def surface(_, _), do: {:error, :workspace_id_required}

  defp run_title(run_id) when is_binary(run_id) and run_id != "", do: "Run " <> short_id(run_id)
  defp run_title(_), do: "Run"

  defp short_id(id) when is_binary(id) and byte_size(id) > 8, do: String.slice(id, 0, 8)
  defp short_id(id) when is_binary(id), do: id

  defp intent_run_id(intent) do
    case Map.get(intent, :run_id) || Map.get(intent, "run_id") do
      id when is_binary(id) ->
        id = String.trim(id)
        if id == "", do: nil, else: id

      _ ->
        nil
    end
  end

  defp intent_request_id(intent) do
    case Map.get(intent, :request_id) || Map.get(intent, "request_id") do
      id when is_binary(id) and id != "" -> id
      _ -> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    end
  end

  defp compact(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
