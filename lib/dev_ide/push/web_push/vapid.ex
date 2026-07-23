defmodule DevIDE.Push.WebPush.Vapid do
  @moduledoc """
  RFC 8292 "Voluntary Application Server Identification" (VAPID). Signs the
  ES256 JWT that authenticates this server to a push service and builds the
  `Authorization: vapid t=…, k=…` header for a given endpoint.

  The ES256 DER→raw signature conversion mirrors `DevIDE.Push.APNSProvider`.
  """

  # JWT lifetime; RFC 8292 requires ≤ 24h. 12h leaves comfortable clock skew.
  @exp_seconds 12 * 60 * 60

  @typedoc "public_key/private_key are raw bytes (65-byte P-256 point / 32-byte scalar)."
  @type config :: %{public_key: binary(), private_key: binary(), subject: String.t()}

  @doc "Build the Authorization header value for `endpoint`."
  @spec authorization(String.t(), config()) :: String.t()
  def authorization(endpoint, %{public_key: pub} = cfg) do
    "vapid t=#{signed_jwt(endpoint_origin(endpoint), cfg)}, k=#{b64(pub)}"
  end

  @doc "The base64url public key the browser passes as `applicationServerKey`."
  @spec public_key_b64(config()) :: String.t()
  def public_key_b64(%{public_key: pub}), do: b64(pub)

  defp signed_jwt(aud, %{private_key: priv, subject: subject}) do
    now = System.system_time(:second)

    header = %{"typ" => "JWT", "alg" => "ES256"} |> Jason.encode!() |> b64()

    claims =
      %{"aud" => aud, "exp" => now + @exp_seconds, "sub" => subject} |> Jason.encode!() |> b64()

    signing_input = header <> "." <> claims

    signature =
      :crypto.sign(:ecdsa, :sha256, signing_input, [priv, :prime256v1])
      |> der_ecdsa_to_raw()
      |> b64()

    signing_input <> "." <> signature
  end

  defp endpoint_origin(endpoint) do
    uri = URI.parse(endpoint)
    "#{uri.scheme}://#{uri.host}"
  end

  # ES256 JWTs carry the raw R||S signature; :crypto returns DER. (Same as APNs.)
  defp der_ecdsa_to_raw(<<0x30, seq_len, rest::binary>>) when byte_size(rest) == seq_len do
    <<0x02, r_len, r::binary-size(r_len), 0x02, s_len, s::binary-size(s_len)>> = rest
    pad_int(r) <> pad_int(s)
  end

  defp pad_int(int) do
    int = strip_leading_zeroes(int)

    cond do
      byte_size(int) == 32 -> int
      byte_size(int) < 32 -> :binary.copy(<<0>>, 32 - byte_size(int)) <> int
      true -> binary_part(int, byte_size(int) - 32, 32)
    end
  end

  defp strip_leading_zeroes(<<0, rest::binary>>), do: strip_leading_zeroes(rest)
  defp strip_leading_zeroes(<<>>), do: <<0>>
  defp strip_leading_zeroes(int), do: int

  defp b64(bin), do: Base.url_encode64(bin, padding: false)
end
