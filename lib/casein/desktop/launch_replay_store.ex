defmodule Casein.Desktop.LaunchReplayStore do
  @moduledoc false

  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec consume(String.t(), integer(), integer()) :: :ok | {:error, :replayed}
  def consume(nonce, expires_at, now \\ System.system_time(:second)) do
    consume(nonce, expires_at, now, __MODULE__)
  end

  @doc false
  def consume(nonce, expires_at, now, server) do
    GenServer.call(server, {:consume, nonce, expires_at, now})
  end

  @doc false
  def reset(server \\ __MODULE__), do: GenServer.call(server, :reset)

  # Path comes from app config / opts, never user input.
  @impl true
  # sobelow_skip ["Traversal.FileModule"]
  def init(opts) do
    case replay_path(opts) do
      nil ->
        {:ok, %{claims: %{}, table: nil}}

      path ->
        File.mkdir_p!(Path.dirname(path))
        :ok = File.chmod(Path.dirname(path), 0o700)
        table = Keyword.get(opts, :table, __MODULE__)
        {:ok, ^table} = :dets.open_file(table, file: String.to_charlist(path), type: :set)
        _ = File.chmod(path, 0o600)

        claims =
          :dets.foldl(fn {nonce, expiry}, acc -> Map.put(acc, nonce, expiry) end, %{}, table)

        {:ok, %{claims: claims, table: table}}
    end
  end

  @impl true
  def handle_call({:consume, nonce, expires_at, now}, _from, state) do
    {expired, claims} = Map.split_with(state.claims, fn {_nonce, expiry} -> expiry < now end)
    delete_persisted(state.table, Map.keys(expired))

    if Map.has_key?(claims, nonce) do
      {:reply, {:error, :replayed}, %{state | claims: claims}}
    else
      persist(state.table, nonce, expires_at)
      {:reply, :ok, %{state | claims: Map.put(claims, nonce, expires_at)}}
    end
  end

  def handle_call(:reset, _from, state) do
    if state.table, do: :ok = :dets.delete_all_objects(state.table)
    {:reply, :ok, %{state | claims: %{}}}
  end

  @impl true
  def terminate(_reason, %{table: nil}), do: :ok
  def terminate(_reason, %{table: table}), do: :dets.close(table)

  defp replay_path(opts) do
    Keyword.get_lazy(opts, :path, fn ->
      if Casein.Desktop.Runtime.desktop_profile?() do
        Path.join([Casein.Desktop.Runtime.data_dir(), "runtime", "launch-replays.dets"])
      end
    end)
  end

  defp persist(nil, _nonce, _expires_at), do: :ok

  defp persist(table, nonce, expires_at) do
    :ok = :dets.insert(table, {nonce, expires_at})
    :ok = :dets.sync(table)
  end

  defp delete_persisted(nil, _nonces), do: :ok

  defp delete_persisted(table, nonces) do
    Enum.each(nonces, &:dets.delete(table, &1))
    if nonces != [], do: :ok = :dets.sync(table)
    :ok
  end
end
