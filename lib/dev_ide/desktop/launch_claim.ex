defmodule Casein.Desktop.LaunchClaim do
  @moduledoc """
  Verifies short-lived, single-use claims minted by a trusted desktop host.

  The long-lived per-install secret never enters the browser URL. Hosts send a
  random nonce, a Unix timestamp, and an HMAC-SHA256 proof over
  `v1.<timestamp>.<nonce>`. Valid nonces are consumed atomically to prevent
  replay during the acceptance window.
  """

  alias Casein.Desktop.LaunchReplayStore

  @maximum_age_seconds 120
  @future_skew_seconds 10
  @nonce_bytes 16
  @proof_bytes 32

  @spec verify_and_consume(map(), String.t(), integer()) :: :ok | {:error, atom()}
  def verify_and_consume(params, secret, now \\ System.system_time(:second))

  def verify_and_consume(params, secret, now)
      when is_map(params) and is_binary(secret) and byte_size(secret) >= 32 and is_integer(now) do
    with {:ok, timestamp} <- parse_timestamp(params["desktop_timestamp"]),
         :ok <- validate_timestamp(timestamp, now),
         {:ok, nonce} <- decode_sized(params["desktop_nonce"], @nonce_bytes),
         {:ok, supplied_proof} <- decode_sized(params["desktop_proof"], @proof_bytes),
         expected_proof <- proof(secret, timestamp, params["desktop_nonce"]),
         true <- :crypto.hash_equals(supplied_proof, expected_proof),
         :ok <- LaunchReplayStore.consume(nonce, timestamp + @maximum_age_seconds, now) do
      :ok
    else
      false -> {:error, :invalid_proof}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_claim}
    end
  end

  def verify_and_consume(_params, _secret, _now), do: {:error, :invalid_claim}

  @doc false
  def proof(secret, timestamp, encoded_nonce) do
    :crypto.mac(:hmac, :sha256, secret, "v1.#{timestamp}.#{encoded_nonce}")
  end

  defp parse_timestamp(value) when is_binary(value) do
    case Integer.parse(value) do
      {timestamp, ""} -> {:ok, timestamp}
      _ -> {:error, :invalid_timestamp}
    end
  end

  defp parse_timestamp(_value), do: {:error, :invalid_timestamp}

  defp validate_timestamp(timestamp, now)
       when timestamp >= now - @maximum_age_seconds and timestamp <= now + @future_skew_seconds,
       do: :ok

  defp validate_timestamp(_timestamp, _now), do: {:error, :expired}

  defp decode_sized(value, size) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, decoded} when byte_size(decoded) == size -> {:ok, decoded}
      _ -> {:error, :invalid_encoding}
    end
  end

  defp decode_sized(_value, _size), do: {:error, :invalid_encoding}
end
