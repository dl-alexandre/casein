defmodule DevIDEPreviewBrowser.ExternalBackend do
  @moduledoc """
  External process backend using a newline-delimited JSON protocol.

  This backend keeps browser runtime crashes outside the BEAM VM. It is a thin
  protocol adapter; concrete implementations can be Electron, CEF, or another
  browser process as long as they speak the request/response/event contract.
  """

  @behaviour DevIDEPreviewBrowser.Backend

  alias DevIDEPreviewBrowser.{ExternalBackend.Worker, Health, Screenshot}

  defstruct [:worker, request_timeout: 5_000]

  @impl true
  def start_runtime(opts) do
    request_timeout = Keyword.get(opts, :request_timeout, 5_000)

    case Worker.start(opts) do
      {:ok, worker} -> {:ok, %__MODULE__{worker: worker, request_timeout: request_timeout}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def open_browser(%__MODULE__{} = state, browser_id, opts) do
    payload = %{
      "browser_id" => browser_id,
      "options" => keyword_to_json_map(opts)
    }

    with {:ok, result} <- request(state, "open_browser", payload) do
      {:ok, state, Map.get(result, "browser_ref", browser_id)}
    end
  end

  @impl true
  def navigate(%__MODULE__{} = state, browser_ref, url) do
    payload = %{"browser_ref" => browser_ref, "url" => url}

    with {:ok, result} <- request(state, "navigate", payload) do
      {:ok, state, observation(result)}
    end
  end

  @impl true
  def observe(%__MODULE__{} = state, browser_ref) do
    with {:ok, result} <- request(state, "observe", %{"browser_ref" => browser_ref}) do
      {:ok, observation(result)}
    end
  end

  @impl true
  def cdp(%__MODULE__{} = state, browser_ref, method, params) do
    payload = %{
      "browser_ref" => browser_ref,
      "method" => method,
      "params" => params
    }

    with {:ok, result} <- request(state, "cdp", payload) do
      {:ok, state, result}
    end
  end

  @impl true
  def screenshot(%__MODULE__{} = state, browser_ref, opts) do
    payload = %{"browser_ref" => browser_ref, "options" => keyword_to_json_map(opts)}

    with {:ok, result} <- request(state, "screenshot", payload),
         {:ok, bytes} <- decode_screenshot_bytes(result) do
      screenshot = %Screenshot{
        mime_type: Map.get(result, "mime_type", "image/png"),
        bytes: bytes,
        metadata: %{
          backend: :external_process,
          url: Map.get(result, "url")
        }
      }

      {:ok, state, screenshot}
    end
  end

  @impl true
  def close_browser(%__MODULE__{} = state, browser_ref) do
    with {:ok, _result} <- request(state, "close_browser", %{"browser_ref" => browser_ref}) do
      {:ok, state}
    end
  end

  @impl true
  def stop_runtime(%__MODULE__{worker: worker}) do
    if Process.alive?(worker), do: GenServer.stop(worker, :normal, 5_000)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp request(%__MODULE__{} = state, command, payload) do
    Worker.request(state.worker, command, payload, state.request_timeout)
  end

  defp observation(result) when is_map(result) do
    %{
      url: Map.get(result, "url"),
      title: Map.get(result, "title"),
      status: Map.get(result, "status"),
      backend: :external_process,
      health: Health.from_map(Map.get(result, "health"))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp decode_screenshot_bytes(%{"data_base64" => encoded}) when is_binary(encoded),
    do: Base.decode64(encoded)

  defp decode_screenshot_bytes(%{"bytes" => bytes}) when is_binary(bytes), do: {:ok, bytes}
  defp decode_screenshot_bytes(_result), do: {:error, :missing_screenshot_bytes}

  defp keyword_to_json_map(opts) when is_list(opts) do
    Map.new(opts, fn {key, value} -> {to_string(key), normalize_json(value)} end)
  end

  defp normalize_json(value) when is_atom(value) and value in [true, false, nil], do: value
  defp normalize_json(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_json(value) when is_list(value), do: Enum.map(value, &normalize_json/1)

  defp normalize_json(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), normalize_json(nested)} end)
  end

  defp normalize_json(value), do: value
end
