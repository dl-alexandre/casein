defmodule DevIDE.Push.Registry do
  @moduledoc """
  In-memory device-token store for push, keyed by workspace and by user. Mirrors
  the other `MemoryAdapter` GenServers — swap for an Ecto-backed store when
  tokens need to survive restarts.

  Workspace registrations also ask `DevIDE.Push.Dispatcher` to watch the
  workspace's audit topic (idempotent), so a token is enough to start receiving
  workspace-scoped alert pushes. User registrations feed mobile-card pushes.
  """
  use GenServer

  alias DevIDE.Push.Dispatcher

  @type entry :: %{token: String.t(), platform: String.t(), user_id: String.t() | nil}

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{workspaces: %{}, users: %{}}, name: __MODULE__)
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

  # state: %{workspaces: %{workspace_id => %{token => entry}}, users: %{user_id => %{token => entry}}}

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:register, wid, token, platform, user_id}, _from, state) do
    entry = %{token: token, platform: platform, user_id: user_id}
    workspaces = Map.get(state, :workspaces, %{})
    by_token = Map.get(workspaces, wid, %{})
    state = %{state | workspaces: Map.put(workspaces, wid, Map.put(by_token, token, entry))}

    # Idempotent — Dispatcher dedups. Ensures alerts for this workspace flow even
    # if it's the first token seen.
    Dispatcher.watch(wid)

    {:reply, :ok, state}
  end

  def handle_call({:register_user, user_id, token, platform}, _from, state) do
    entry = %{token: token, platform: platform, user_id: user_id}
    users = Map.get(state, :users, %{})
    by_token = Map.get(users, user_id, %{})
    state = %{state | users: Map.put(users, user_id, Map.put(by_token, token, entry))}

    {:reply, :ok, state}
  end

  def handle_call({:unregister, token}, _from, state) do
    workspaces =
      state
      |> Map.get(:workspaces, %{})
      |> Enum.map(fn {wid, by_token} -> {wid, Map.delete(by_token, token)} end)
      |> Map.new()

    users =
      state
      |> Map.get(:users, %{})
      |> Enum.map(fn {user_id, by_token} -> {user_id, Map.delete(by_token, token)} end)
      |> Map.new()

    {:reply, :ok, %{state | workspaces: workspaces, users: users}}
  end

  def handle_call({:tokens_for, wid}, _from, state) do
    tokens =
      state
      |> Map.get(:workspaces, %{})
      |> Map.get(wid, %{})
      |> Map.values()

    {:reply, tokens, state}
  end

  def handle_call({:tokens_for_user, user_id}, _from, state) do
    tokens =
      state
      |> Map.get(:users, %{})
      |> Map.get(user_id, %{})
      |> Map.values()

    {:reply, tokens, state}
  end

  def handle_call(:clear, _from, _state), do: {:reply, :ok, %{workspaces: %{}, users: %{}}}
end
