defmodule Casein.Agents.JidoWorkcell.Git.Ledger do
  @moduledoc "Restart-safe idempotency ledger for one Workcell Git handoff id."

  use GenServer

  alias Casein.Agents.JidoWorkcell.{Receipt, ResourceStore}

  @timeout :infinity

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec run(String.t(), term(), (-> {:ok, map()} | {:error, term()})) ::
          {:ok, map()} | {:error, term()}
  def run(handoff_id, fingerprint, fun)
      when is_binary(handoff_id) and is_function(fun, 0) do
    run(handoff_id, fingerprint, nil, fun)
  end

  @doc "Run or replay a handoff, rejecting a reused id with a different head SHA."
  @spec run(String.t(), term(), String.t() | nil, (-> {:ok, map()} | {:error, term()})) ::
          {:ok, map()} | {:error, term()}
  def run(handoff_id, fingerprint, expected_head_sha, fun)
      when is_binary(handoff_id) and is_function(fun, 0) and
             (is_binary(expected_head_sha) or is_nil(expected_head_sha)) do
    run(handoff_id, fingerprint, expected_head_sha, nil, fun)
  end

  @doc "Run or replay a handoff while binding its durable result to one Workcell."
  @spec run(
          String.t(),
          term(),
          String.t() | nil,
          String.t() | nil,
          (-> {:ok, map()} | {:error, term()})
        ) :: {:ok, map()} | {:error, term()}
  def run(handoff_id, fingerprint, expected_head_sha, workcell_id, fun)
      when is_binary(handoff_id) and is_function(fun, 0) and
             (is_binary(expected_head_sha) or is_nil(expected_head_sha)) and
             (is_binary(workcell_id) or is_nil(workcell_id)) do
    ensure_started()

    GenServer.call(
      __MODULE__,
      {:run, handoff_id, fingerprint, expected_head_sha, workcell_id, fun},
      @timeout
    )
  end

  @impl true
  def init(_state), do: {:ok, hydrate()}

  @impl true
  def handle_call(
        {:run, handoff_id, fingerprint, expected_head_sha, workcell_id, fun},
        _from,
        state
      ) do
    case Map.get(state, handoff_id) do
      %{fingerprint: ^fingerprint, head_sha: stored_head_sha, receipt: receipt} ->
        cond do
          not is_map(receipt) ->
            {:reply, {:error, :idempotency_replay_unavailable}, state}

          is_nil(expected_head_sha) or expected_head_sha == stored_head_sha ->
            {:reply, {:ok, receipt}, state}

          true ->
            {:reply, {:error, :reused_handoff_new_sha}, state}
        end

      %{fingerprint: _other, head_sha: stored_head_sha} ->
        error =
          if is_binary(expected_head_sha) and expected_head_sha != stored_head_sha,
            do: :reused_handoff_new_sha,
            else: :idempotency_mismatch

        {:reply, {:error, error}, state}

      nil ->
        case fun.() do
          {:ok, receipt} = result ->
            case canonical_idempotency(handoff_id, receipt) do
              :ok ->
                entry = %{
                  handoff_id: handoff_id,
                  fingerprint: fingerprint,
                  head_sha: Receipt.head_sha(receipt),
                  handoff_key: idempotency_key(receipt),
                  receipt: receipt,
                  workcell_id: workcell_id
                }

                _ = persist_entry(entry)
                {:reply, result, Map.put(state, handoff_id, entry)}

              {:error, reason} ->
                {:reply, {:error, reason}, state}
            end

          other ->
            {:reply, other, state}
        end
    end
  end

  defp hydrate do
    ResourceStore.list()
    |> Enum.reduce(%{}, fn resource, state ->
      resource
      |> Map.get(:idempotency, %{})
      |> Enum.reduce(state, fn {handoff_id, entry}, state ->
        if is_map(entry) and is_binary(handoff_id) and is_map(Map.get(entry, :receipt)) do
          Map.put(state, handoff_id, Map.put(entry, :workcell_id, resource[:workcell_id]))
        else
          state
        end
      end)
    end)
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  defp persist_entry(%{workcell_id: workcell_id} = entry) when is_binary(workcell_id) do
    ResourceStore.record_idempotency(workcell_id, entry)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp persist_entry(_entry), do: :ok

  defp idempotency_key(receipt) when is_map(receipt),
    do: Map.get(receipt, :idempotency, Map.get(receipt, "idempotency")) |> handoff_key()

  defp idempotency_key(_receipt), do: nil

  defp handoff_key(%{} = idempotency),
    do: Map.get(idempotency, :handoff_key, Map.get(idempotency, "handoff_key"))

  defp handoff_key(_idempotency), do: nil

  defp canonical_idempotency(handoff_id, receipt) do
    sha = Receipt.head_sha(receipt)
    key = idempotency_key(receipt)

    if Receipt.valid_sha?(sha) and key == Receipt.idempotency_key(handoff_id, sha),
      do: :ok,
      else: {:error, :idempotency_mismatch}
  end

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        case start_link([]) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> exit({:handoff_ledger_unavailable, reason})
        end

      _pid ->
        :ok
    end
  end
end
