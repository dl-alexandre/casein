defmodule DevIDEPreviewBrowser.Session do
  @moduledoc """
  GenServer that owns one browser backend runtime and its browser instances.
  """

  use GenServer

  alias DevIDEPreviewBrowser.Browser

  @default_backend DevIDEPreviewBrowser.FakeBackend

  defstruct [
    :backend,
    :backend_state,
    :event_owner,
    browsers: %{}
  ]

  @type browser_entry :: %{
          backend_ref: term()
        }

  @type state :: %__MODULE__{
          backend: module(),
          backend_state: term(),
          event_owner: pid(),
          browsers: %{Browser.id() => browser_entry()}
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, {self(), opts}, name: Keyword.get(opts, :name))
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :temporary,
      shutdown: 5_000
    }
  end

  @spec open_browser(GenServer.server(), keyword()) ::
          {:ok, Browser.t()} | {:error, term()}
  def open_browser(session, opts \\ []), do: GenServer.call(session, {:open_browser, opts})

  @spec navigate(Browser.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def navigate(%Browser{} = browser, url), do: call_browser(browser, {:navigate, url})

  @spec observe(Browser.t()) :: {:ok, map()} | {:error, term()}
  def observe(%Browser{} = browser), do: call_browser(browser, :observe)

  @spec cdp(Browser.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def cdp(%Browser{} = browser, method, params),
    do: call_browser(browser, {:cdp, method, params})

  @spec screenshot(Browser.t(), keyword()) ::
          {:ok, DevIDEPreviewBrowser.Screenshot.t()} | {:error, term()}
  def screenshot(%Browser{} = browser, opts \\ []), do: call_browser(browser, {:screenshot, opts})

  @spec close(Browser.t()) :: :ok | {:error, term()}
  def close(%Browser{} = browser), do: call_browser(browser, :close)

  @spec emit_event(GenServer.server(), Browser.id(), term()) :: :ok
  def emit_event(session, browser_id, event) do
    GenServer.cast(session, {:emit_event, browser_id, event})
    :ok
  end

  @impl true
  def init({caller, opts}) do
    backend = Keyword.get(opts, :backend, @default_backend)
    event_owner = Keyword.get(opts, :event_owner, caller)

    case backend.start_runtime(opts) do
      {:ok, backend_state} ->
        {:ok,
         %__MODULE__{
           backend: backend,
           backend_state: backend_state,
           event_owner: event_owner
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:open_browser, opts}, _from, %__MODULE__{} = state) do
    id = browser_id()

    case state.backend.open_browser(state.backend_state, id, opts) do
      {:ok, backend_state, backend_ref} ->
        browser = %Browser{id: id, session: self()}
        browsers = Map.put(state.browsers, id, %{backend_ref: backend_ref})
        {:reply, {:ok, browser}, %{state | backend_state: backend_state, browsers: browsers}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:browser_call, browser_id, :observe}, _from, %__MODULE__{} = state) do
    with {:ok, entry} <- fetch_browser(state, browser_id),
         {:ok, observation} <- state.backend.observe(state.backend_state, entry.backend_ref) do
      {:reply, {:ok, observation}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:browser_call, browser_id, {:navigate, url}}, _from, %__MODULE__{} = state) do
    with {:ok, entry} <- fetch_browser(state, browser_id),
         :ok <- emit(state, browser_id, {:load_started, url}),
         {:ok, backend_state, observation} <-
           state.backend.navigate(state.backend_state, entry.backend_ref, url) do
      status = Map.get(observation, :status) || Map.get(observation, "status") || 200
      :ok = emit(state, browser_id, {:load_finished, url, status})
      {:reply, {:ok, observation}, %{state | backend_state: backend_state}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:browser_call, browser_id, {:cdp, method, params}},
        _from,
        %__MODULE__{} = state
      ) do
    with {:ok, entry} <- fetch_browser(state, browser_id),
         {:ok, backend_state, result} <-
           state.backend.cdp(state.backend_state, entry.backend_ref, method, params) do
      {:reply, {:ok, result}, %{state | backend_state: backend_state}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:browser_call, browser_id, {:screenshot, opts}}, _from, %__MODULE__{} = state) do
    with {:ok, entry} <- fetch_browser(state, browser_id),
         {:ok, backend_state, screenshot} <-
           state.backend.screenshot(state.backend_state, entry.backend_ref, opts) do
      {:reply, {:ok, screenshot}, %{state | backend_state: backend_state}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:browser_call, browser_id, :close}, _from, %__MODULE__{} = state) do
    with {:ok, entry} <- fetch_browser(state, browser_id),
         {:ok, backend_state} <-
           state.backend.close_browser(state.backend_state, entry.backend_ref) do
      :ok = emit(state, browser_id, :closed)

      {:reply, :ok,
       %{state | backend_state: backend_state, browsers: Map.delete(state.browsers, browser_id)}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:emit_event, browser_id, event}, %__MODULE__{} = state) do
    :ok = emit(state, browser_id, event)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %__MODULE__{} = state) do
    if function_exported?(state.backend, :stop_runtime, 1) do
      state.backend.stop_runtime(state.backend_state)
    end

    :ok
  end

  defp call_browser(%Browser{id: id, session: session}, command),
    do: GenServer.call(session, {:browser_call, id, command})

  defp fetch_browser(%__MODULE__{} = state, browser_id) do
    case Map.fetch(state.browsers, browser_id) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, :browser_not_found}
    end
  end

  defp emit(%__MODULE__{event_owner: owner}, browser_id, event) when is_pid(owner) do
    send(owner, {:preview_browser, browser_id, event})
    :ok
  end

  defp browser_id do
    "browser-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end
end
