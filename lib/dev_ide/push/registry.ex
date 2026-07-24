defmodule Casein.Push.Registry do
  @moduledoc """
  Persistent device-token registry for push, keyed by workspace and by user.

  Workspace registrations also ask `Casein.Signals.AlertsRouter` to watch the
  workspace (idempotent), so a token is enough to start receiving workspace-scoped
  alert pushes routed from the signal bus. User registrations feed mobile-card pushes.
  """
  use GenServer

  import Ecto.Query

  alias Casein.Push.Device
  alias Casein.Signals.AlertsRouter
  alias Casein.Repo

  @type entry :: %{token: String.t(), platform: String.t(), user_id: String.t() | nil}

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, initial_state(), name: __MODULE__)
  end

  @doc "Register (or refresh) a device token for a workspace."
  @spec register(%{
          required(:workspace_id) => String.t(),
          required(:token) => String.t(),
          required(:platform) => String.t(),
          optional(:user_id) => String.t() | nil
        }) :: :ok
  def register(%{workspace_id: wid, token: token, platform: platform} = attrs)
      when is_binary(wid) and is_binary(token) and is_binary(platform) do
    GenServer.call(__MODULE__, {:register, wid, token, platform, Map.get(attrs, :user_id)})
  end

  @doc "Register (or refresh) a device token for the user's mobile card stream."
  @spec register_user(%{
          required(:user_id) => String.t(),
          required(:token) => String.t(),
          required(:platform) => String.t()
        }) :: :ok
  def register_user(%{user_id: user_id, token: token, platform: platform})
      when is_binary(user_id) and is_binary(token) and is_binary(platform) do
    GenServer.call(__MODULE__, {:register_user, user_id, token, platform})
  end

  @doc "Remove a token from every workspace (e.g. on unregister or invalidation)."
  @spec unregister(String.t()) :: :ok
  def unregister(token) when is_binary(token) do
    GenServer.call(__MODULE__, {:unregister, token})
  end

  @spec tokens_for(String.t()) :: [entry()]
  def tokens_for(workspace_id) when is_binary(workspace_id) do
    GenServer.call(__MODULE__, {:tokens_for, workspace_id})
  end

  @spec tokens_for_user(String.t()) :: [entry()]
  def tokens_for_user(user_id) when is_binary(user_id) do
    GenServer.call(__MODULE__, {:tokens_for_user, user_id})
  end

  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear)

  @spec record_failure(String.t(), term()) :: :ok
  def record_failure(token, reason) when is_binary(token) do
    GenServer.call(__MODULE__, {:record_failure, token, reason})
  end

  @spec list_devices(keyword()) :: [Device.t()]
  def list_devices(opts \\ []) do
    GenServer.call(__MODULE__, {:list_devices, opts})
  end

  @spec stats() :: map()
  def stats, do: GenServer.call(__MODULE__, :stats)

  @impl true
  def init(state) do
    {:ok, state, {:continue, :load_devices}}
  end

  @impl true
  def handle_continue(:load_devices, state) do
    {:noreply, load_persisted_devices(state)}
  end

  @impl true
  def handle_call({:register, wid, token, platform, user_id}, _from, state) do
    now = now()

    :ok =
      upsert_device(%{
        token: token,
        platform: platform,
        scope: "workspace",
        scope_id: wid,
        workspace_id: wid,
        user_id: user_id,
        last_seen_at: now
      })

    # Idempotent — Dispatcher dedups. Ensures alerts for this workspace flow even
    # if it's the first token seen.
    state =
      state
      |> watch_workspace(wid)
      |> put_workspace_entry(wid, entry(token, platform, user_id))

    {:reply, :ok, state}
  end

  def handle_call({:register_user, user_id, token, platform}, _from, state) do
    :ok =
      upsert_device(%{
        token: token,
        platform: platform,
        scope: "user",
        scope_id: user_id,
        user_id: user_id,
        last_seen_at: now()
      })

    state = put_user_entry(state, user_id, entry(token, platform, user_id))

    {:reply, :ok, state}
  end

  def handle_call({:unregister, token}, _from, state) do
    disable_token(token, "invalid")
    {:reply, :ok, remove_token(state, token)}
  end

  def handle_call({:tokens_for, wid}, _from, state) do
    {:reply, state.workspaces |> Map.get(wid, %{}) |> Map.values(), state}
  end

  def handle_call({:tokens_for_user, user_id}, _from, state) do
    {:reply, state.users |> Map.get(user_id, %{}) |> Map.values(), state}
  end

  def handle_call({:record_failure, token, reason}, _from, state) do
    token_hash = token_hash(token)
    invalid? = invalid_token_error?(reason)
    status = if invalid?, do: "invalid", else: "failed"
    now = now()

    updates = [
      inc: [failure_count: 1],
      set: [provider_status: status, updated_at: now]
    ]

    updates =
      if invalid?,
        do: Keyword.update!(updates, :set, &[{:disabled_at, now} | &1]),
        else: updates

    Device
    |> where([d], d.token_hash == ^token_hash)
    |> Repo.update_all(updates)

    emit(:failure, %{reason: inspect(reason), invalid?: invalid?})
    state = if invalid?, do: remove_token(state, token), else: state
    {:reply, :ok, state}
  end

  def handle_call({:list_devices, opts}, _from, state) do
    limit = opts |> Keyword.get(:limit, 50) |> clamp_limit()

    devices =
      Device
      |> order_by([d], desc: d.last_seen_at)
      |> limit(^limit)
      |> Repo.all()

    {:reply, devices, state}
  end

  def handle_call(:stats, _from, state) do
    rows =
      Device
      |> group_by([d], [d.provider_status, is_nil(d.disabled_at)])
      |> select([d], {d.provider_status, is_nil(d.disabled_at), count(d.id)})
      |> Repo.all()

    stats =
      Enum.reduce(rows, %{active: 0, disabled: 0, by_status: %{}}, fn {status, active?, count},
                                                                      acc ->
        key = if active?, do: :active, else: :disabled

        acc
        |> Map.update!(key, &(&1 + count))
        |> update_in([:by_status, status], &((&1 || 0) + count))
      end)

    {:reply, stats, state}
  end

  def handle_call(:clear, _from, _state) do
    Repo.delete_all(Device)
    {:reply, :ok, initial_state()}
  end

  defp initial_state, do: %{watched: MapSet.new(), workspaces: %{}, users: %{}}

  defp upsert_device(attrs) do
    attrs =
      attrs
      |> Map.put(:token_hash, token_hash(attrs.token))
      |> Map.put_new(:push_subscription, %{})
      |> Map.put(:disabled_at, nil)
      |> Map.put(:failure_count, 0)
      |> Map.put(:provider_status, "active")

    %Device{}
    |> Device.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [
           :token,
           :platform,
           :user_id,
           :workspace_id,
           :device_link_id,
           :push_subscription,
           :last_seen_at,
           :disabled_at,
           :failure_count,
           :provider_status,
           :updated_at
         ]},
      conflict_target: [:token_hash, :scope, :scope_id]
    )
    |> case do
      {:ok, _device} ->
        emit(:register, %{scope: attrs.scope, platform: attrs.platform})
        :ok

      {:error, changeset} ->
        raise ArgumentError, "invalid push registration: #{inspect(changeset.errors)}"
    end
  end

  defp entry(token, platform, user_id), do: %{token: token, platform: platform, user_id: user_id}
  defp entry(%Device{} = device), do: entry(device.token, device.platform, device.user_id)

  defp disable_token(token, status) do
    token_hash = token_hash(token)
    now = now()

    Device
    |> where([d], d.token_hash == ^token_hash)
    |> Repo.update_all(set: [disabled_at: now, provider_status: status, updated_at: now])

    emit(:unregister, %{status: status})
    :ok
  end

  defp load_persisted_devices(state) do
    devices =
      try do
        Device
        |> where([d], is_nil(d.disabled_at))
        |> order_by([d], desc: d.last_seen_at)
        |> limit(1_000)
        |> Repo.all()
      rescue
        _ -> []
      end

    Enum.reduce(devices, state, fn
      %Device{scope: "workspace", scope_id: workspace_id} = device, state ->
        state
        |> put_workspace_entry(workspace_id, entry(device))
        |> watch_workspace(workspace_id)

      %Device{scope: "user", scope_id: user_id} = device, state ->
        put_user_entry(state, user_id, entry(device))

      _device, state ->
        state
    end)
  end

  defp watch_workspace(%{watched: watched} = state, workspace_id) do
    if MapSet.member?(watched, workspace_id) do
      state
    else
      :ok = AlertsRouter.watch(workspace_id)
      %{state | watched: MapSet.put(watched, workspace_id)}
    end
  end

  defp put_workspace_entry(state, workspace_id, %{token: token} = entry) do
    workspaces =
      Map.update(state.workspaces, workspace_id, %{token => entry}, fn by_token ->
        Map.put(by_token, token, entry)
      end)

    %{state | workspaces: workspaces}
  end

  defp put_user_entry(state, user_id, %{token: token} = entry) do
    users =
      Map.update(state.users, user_id, %{token => entry}, fn by_token ->
        Map.put(by_token, token, entry)
      end)

    %{state | users: users}
  end

  defp remove_token(state, token) do
    workspaces =
      Map.new(state.workspaces, fn {workspace_id, by_token} ->
        {workspace_id, Map.delete(by_token, token)}
      end)

    users =
      Map.new(state.users, fn {user_id, by_token} ->
        {user_id, Map.delete(by_token, token)}
      end)

    %{state | workspaces: workspaces, users: users}
  end

  defp token_hash(token) do
    :crypto.hash(:sha256, token)
    |> Base.encode16(case: :lower)
  end

  defp now do
    DateTime.utc_now()
    |> then(fn %DateTime{microsecond: {usec, _}} = dt -> %{dt | microsecond: {usec, 6}} end)
  end

  defp clamp_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(200)

  defp clamp_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {int, ""} -> clamp_limit(int)
      _ -> 50
    end
  end

  defp clamp_limit(_limit), do: 50

  defp invalid_token_error?(:invalid_token), do: true
  defp invalid_token_error?({:invalid_token, _reason}), do: true
  defp invalid_token_error?({:fcm_status, status}) when status in [404, 410], do: true
  defp invalid_token_error?({:apns_status, status, _reason}) when status in [400, 410], do: true
  defp invalid_token_error?(_reason), do: false

  defp emit(operation, metadata) do
    :telemetry.execute(
      [:casein, :push, :registry],
      %{count: 1},
      Map.put(metadata, :operation, operation)
    )
  end
end
