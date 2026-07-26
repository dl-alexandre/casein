defmodule CaseinPreviewBrowser.Adapter do
  @moduledoc """
  Adapter-shaped boundary for host preview orchestration.

  This module intentionally does not declare `@behaviour PreviewCtl.Adapter`:
  `casein_preview_browser` is a standalone sibling library and must not depend
  back on the host Casein application. It implements the same callback-shaped
  functions so the host can wire it into `PreviewCtl` later without exposing
  browser backend details.
  """

  alias CaseinPreviewBrowser.{Browser, Screenshot}

  @runtime_opt_keys [:backend, :event_owner, :executable, :args, :request_timeout]
  @browser_opt_keys [
    :default_headers,
    :storage_profile,
    :storage_profile_name,
    :storage_profile_key,
    :storage_state_path
  ]

  @type state :: %{
          required(:session) => GenServer.server(),
          required(:browser) => Browser.t(),
          required(:current_url) => String.t(),
          optional(:last_observation) => map()
        }

  @doc "Start a preview-browser session and open one browser instance."
  @spec start_session(map()) :: {:ok, state()} | {:error, term()}
  def start_session(%{current_url: url} = session) when is_binary(url) and url != "" do
    with {:ok, runtime} <- CaseinPreviewBrowser.start_link(runtime_opts(session)),
         {:ok, browser} <- CaseinPreviewBrowser.open_browser(runtime, browser_opts(session)) do
      state = %{
        session: runtime,
        browser: browser,
        current_url: url
      }

      case CaseinPreviewBrowser.observe(browser) do
        {:ok, observation} -> {:ok, put_observation(state, observation, url)}
        {:error, _reason} -> {:ok, state}
      end
    end
  end

  def start_session(_session), do: {:error, :missing_url}

  @doc "Navigate the browser to a caller-approved URL."
  @spec navigate(state(), String.t()) :: {:ok, state(), map()} | {:error, term()}
  def navigate(%{browser: %Browser{} = browser} = state, url) when is_binary(url) do
    with {:ok, observation} <- CaseinPreviewBrowser.navigate(browser, url) do
      {:ok, put_observation(state, observation, url), observation}
    end
  end

  @doc "Browser history back is intentionally unsupported in the first backend slice."
  @spec go_back(state()) :: {:error, term()}
  def go_back(_state), do: unsupported(:go_back)

  @doc "Browser history forward is intentionally unsupported in the first backend slice."
  @spec go_forward(state()) :: {:error, term()}
  def go_forward(_state), do: unsupported(:go_forward)

  @doc "Reload by navigating to the current URL."
  @spec reload(state()) :: {:ok, state(), map()} | {:error, term()}
  def reload(%{current_url: url} = state) when is_binary(url) and url != "",
    do: navigate(state, url)

  def reload(_state), do: {:error, :missing_url}

  @doc "Return the latest browser observation."
  @spec observe(state()) :: {:ok, map()} | {:error, term()}
  def observe(%{browser: %Browser{} = browser}), do: CaseinPreviewBrowser.observe(browser)

  @doc "Live observation currently maps to the same backend observation call."
  @spec observe_live(state()) :: {:ok, state(), map()} | {:error, term()}
  def observe_live(%{browser: %Browser{} = browser} = state) do
    with {:ok, observation} <- CaseinPreviewBrowser.observe(browser) do
      {:ok, put_observation(state, observation), observation}
    end
  end

  @doc "DOM interaction is not part of the first browser backend slice."
  @spec click(state(), map()) :: {:error, term()}
  def click(_state, _target), do: unsupported(:click)

  @doc "DOM interaction is not part of the first browser backend slice."
  @spec type(state(), String.t(), String.t(), map()) :: {:error, term()}
  def type(_state, _selector, _text, _opts \\ %{}), do: unsupported(:type)

  @doc "Keyboard interaction is not part of the first browser backend slice."
  @spec press(state(), String.t(), map()) :: {:error, term()}
  def press(_state, _key, _opts \\ %{}), do: unsupported(:press)

  @doc "Capture a screenshot and return a PreviewCtl-compatible artifact value."
  @spec screenshot(state()) :: {:ok, state(), map(), String.t() | nil} | {:error, term()}
  def screenshot(%{browser: %Browser{} = browser} = state) do
    with {:ok, %Screenshot{} = screenshot} <- CaseinPreviewBrowser.screenshot(browser),
         {:ok, observation} <- observe(state) do
      observation =
        Map.put(observation, :screenshot, %{
          mime_type: screenshot.mime_type,
          byte_size: byte_size(screenshot.bytes),
          metadata: screenshot.metadata
        })

      {:ok, put_observation(state, observation), observation, artifact_data_url(screenshot)}
    end
  end

  @doc "Storage inspection is not part of the first browser backend slice."
  @spec get_storage(state()) :: {:error, term()}
  def get_storage(_state), do: unsupported(:get_storage)

  @doc "Cookie injection is not part of the first browser backend slice."
  @spec set_cookies(state(), [map()]) :: {:error, term()}
  def set_cookies(_state, _cookies), do: unsupported(:set_cookies)

  @doc "Storage mutation is not part of the first browser backend slice."
  @spec clear_storage(state()) :: {:error, term()}
  def clear_storage(_state), do: unsupported(:clear_storage)

  @doc "Server-side recording is not part of the first browser backend slice."
  @spec record_start(state(), keyword()) :: {:error, term()}
  def record_start(_state, _opts), do: unsupported(:record_start)

  @doc "Server-side recording is not part of the first browser backend slice."
  @spec record_stop(state()) :: {:error, term()}
  def record_stop(_state), do: unsupported(:record_stop)

  @doc "Close the browser instance and stop its runtime process."
  @spec close(state()) :: :ok
  def close(%{browser: %Browser{} = browser, session: session}) do
    _ = CaseinPreviewBrowser.close(browser)
    stop_session(session)
    :ok
  end

  def close(_state), do: :ok

  defp runtime_opts(session) do
    session
    |> take_present(@runtime_opt_keys)
    |> Keyword.put_new(:event_owner, self())
  end

  defp browser_opts(%{current_url: url} = session) do
    session
    |> take_present(@browser_opt_keys)
    |> Keyword.put(:url, url)
  end

  defp take_present(map, keys) do
    keys
    |> Enum.flat_map(fn key ->
      case Map.fetch(map, key) do
        {:ok, nil} -> []
        {:ok, value} -> [{key, value}]
        :error -> []
      end
    end)
  end

  defp put_observation(state, observation, url \\ nil) do
    state
    |> Map.put(:current_url, url || observation_url(observation) || state.current_url)
    |> Map.put(:last_observation, observation)
  end

  defp observation_url(observation) when is_map(observation) do
    Map.get(observation, :url) || Map.get(observation, "url")
  end

  defp artifact_data_url(%Screenshot{mime_type: "image/png", bytes: bytes}) when is_binary(bytes),
    do: "data:image/png;base64," <> Base.encode64(bytes)

  defp artifact_data_url(_screenshot), do: nil

  defp stop_session(session) when is_pid(session) do
    if Process.alive?(session), do: GenServer.stop(session, :normal, 5_000)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp stop_session(_session), do: :ok

  defp unsupported(operation), do: {:error, {:unsupported_operation, operation}}
end
