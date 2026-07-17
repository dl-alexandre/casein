defmodule DevIDE.Codex.JsonRpc do
  @moduledoc """
  Small JSON-RPC codec for Codex App Server's newline-delimited stdio protocol.

  App Server intentionally omits the conventional `jsonrpc: "2.0"` member on
  the wire. The codec accepts it when present but never emits it.
  """

  @type request_id :: integer() | String.t()
  @type decoded ::
          {:request, request_id(), String.t(), map()}
          | {:notification, String.t(), map()}
          | {:response, request_id(), term()}
          | {:error_response, request_id(), map()}

  @spec encode_request(request_id(), String.t(), map()) :: binary()
  def encode_request(id, method, params \\ %{}) do
    encode!(%{"id" => valid_id!(id), "method" => valid_method!(method), "params" => params})
  end

  @spec encode_notification(String.t(), map()) :: binary()
  def encode_notification(method, params \\ %{}) do
    encode!(%{"method" => valid_method!(method), "params" => params})
  end

  @spec encode_result(request_id(), term()) :: binary()
  def encode_result(id, result), do: encode!(%{"id" => valid_id!(id), "result" => result})

  @spec encode_error(request_id(), integer(), String.t(), term() | nil) :: binary()
  def encode_error(id, code, message, data \\ nil)
      when is_integer(code) and is_binary(message) do
    error = %{"code" => code, "message" => message}
    error = if is_nil(data), do: error, else: Map.put(error, "data", data)
    encode!(%{"id" => valid_id!(id), "error" => error})
  end

  @spec decode(binary()) :: {:ok, decoded()} | {:error, :invalid_json | :invalid_message}
  def decode(line) when is_binary(line) do
    with {:ok, message} when is_map(message) <- Jason.decode(line) do
      classify(message)
    else
      {:ok, _other} -> {:error, :invalid_message}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp classify(%{"id" => id, "method" => method} = message)
       when (is_integer(id) or is_binary(id)) and is_binary(method) and method != "" do
    with {:ok, params} <- params(message) do
      {:ok, {:request, id, method, params}}
    end
  end

  defp classify(%{"method" => method} = message) when is_binary(method) and method != "" do
    with {:ok, params} <- params(message) do
      {:ok, {:notification, method, params}}
    end
  end

  defp classify(%{"id" => id, "error" => error})
       when (is_integer(id) or is_binary(id)) and is_map(error),
       do: {:ok, {:error_response, id, error}}

  defp classify(%{"id" => id, "result" => result}) when is_integer(id) or is_binary(id),
    do: {:ok, {:response, id, result}}

  defp classify(_message), do: {:error, :invalid_message}

  defp params(message) do
    case Map.get(message, "params", %{}) do
      params when is_map(params) -> {:ok, params}
      _other -> {:error, :invalid_message}
    end
  end

  defp encode!(message), do: Jason.encode!(message) <> "\n"

  defp valid_id!(id) when is_integer(id) or is_binary(id), do: id
  defp valid_id!(_id), do: raise(ArgumentError, "JSON-RPC request id must be a string or integer")

  defp valid_method!(method) when is_binary(method) and method != "", do: method
  defp valid_method!(_method), do: raise(ArgumentError, "JSON-RPC method must be non-empty")
end
