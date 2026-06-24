defmodule DevIDEPreviewBrowser.ExternalBackend.Protocol do
  @moduledoc """
  Newline-delimited JSON protocol for external browser sidecars.
  """

  alias DevIDEPreviewBrowser.Health

  @type response :: {:ok, map()} | {:error, term()}
  @type decoded :: {:response, String.t(), response()} | {:event, String.t(), term()} | :ignore

  @spec encode_request(String.t(), String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def encode_request(id, command, payload)
      when is_binary(id) and is_binary(command) and is_map(payload) do
    %{"id" => id, "command" => command, "payload" => payload}
    |> Jason.encode()
  end

  @spec decode_line(String.t()) :: {:ok, decoded()} | {:error, term()}
  def decode_line(line) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, message} -> decode_message(message)
      {:error, reason} -> {:error, {:decode_failed, reason}}
    end
  end

  defp decode_message(%{"type" => "event", "browser_id" => browser_id, "event" => event})
       when is_binary(browser_id) do
    {:ok, {:event, browser_id, normalize_event(event)}}
  end

  defp decode_message(%{"id" => id} = message) when is_binary(id) do
    {:ok, {:response, id, response(message)}}
  end

  defp decode_message(_message), do: {:ok, :ignore}

  defp response(%{"ok" => true} = message), do: {:ok, Map.get(message, "result", %{})}

  defp response(%{"ok" => false} = message),
    do: {:error, Map.get(message, "error", :backend_error)}

  defp response(message), do: {:error, {:invalid_response, message}}

  defp normalize_event(["console", level, text]), do: {:console, console_level(level), text}
  defp normalize_event(["crashed", reason]), do: {:crashed, reason}
  defp normalize_event(["health", health]), do: {:health, Health.from_map(health)}
  defp normalize_event(["load_started", url]), do: {:load_started, url}
  defp normalize_event(["load_finished", url, status]), do: {:load_finished, url, status}

  defp normalize_event(["preview_signal", type, payload])
       when is_binary(type) and is_map(payload),
       do: {:preview_signal, type, payload}

  defp normalize_event(["preview_signal", type, payload, health])
       when is_binary(type) and is_map(payload),
       do: {:preview_signal, type, payload, Health.from_map(health)}

  defp normalize_event(event), do: event

  defp console_level("debug"), do: :debug
  defp console_level("log"), do: :log
  defp console_level("info"), do: :info
  defp console_level("warning"), do: :warning
  defp console_level("error"), do: :error
  defp console_level(level), do: level
end
