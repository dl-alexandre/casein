defmodule DevIDE.Push.WebPush.VapidTest do
  use ExUnit.Case, async: true

  alias DevIDE.Push.WebPush.Vapid

  defp cfg do
    {public, private} = :crypto.generate_key(:ecdh, :prime256v1)
    %{public_key: public, private_key: private, subject: "mailto:ops@example.com"}
  end

  test "builds a vapid Authorization header with the audience origin and public key" do
    cfg = cfg()
    auth = Vapid.authorization("https://fcm.googleapis.com/fcm/send/abc123", cfg)

    assert "vapid t=" <> rest = auth
    [jwt, "k=" <> key] = String.split(rest, ", ")
    assert key == Vapid.public_key_b64(cfg)

    [header_b64, claims_b64, sig_b64] = String.split(jwt, ".")
    header = header_b64 |> b64d() |> Jason.decode!()
    claims = claims_b64 |> b64d() |> Jason.decode!()

    assert header["alg"] == "ES256"
    assert claims["aud"] == "https://fcm.googleapis.com"
    assert claims["sub"] == "mailto:ops@example.com"
    assert is_integer(claims["exp"])

    # Raw ES256 signature is exactly R||S (64 bytes).
    assert byte_size(b64d(sig_b64)) == 64
  end

  test "the ES256 signature verifies against the VAPID public key" do
    cfg = cfg()
    auth = Vapid.authorization("https://updates.push.services.mozilla.com/wpush/v2/xyz", cfg)
    "vapid t=" <> rest = auth
    [jwt, _key] = String.split(rest, ", ")
    [header_b64, claims_b64, sig_b64] = String.split(jwt, ".")

    signing_input = header_b64 <> "." <> claims_b64
    der = raw_to_der(b64d(sig_b64))

    assert :crypto.verify(:ecdsa, :sha256, signing_input, der, [cfg.public_key, :prime256v1])
  end

  defp b64d(s), do: Base.url_decode64!(s, padding: false)

  # Reassemble a DER ECDSA signature from the JWT's raw R||S so :crypto can verify.
  defp raw_to_der(<<r::binary-size(32), s::binary-size(32)>>) do
    r_der = der_int(r)
    s_der = der_int(s)
    body = r_der <> s_der
    <<0x30, byte_size(body)>> <> body
  end

  defp der_int(bytes) do
    trimmed = strip(bytes)
    trimmed = if :binary.first(trimmed) >= 0x80, do: <<0>> <> trimmed, else: trimmed
    <<0x02, byte_size(trimmed)>> <> trimmed
  end

  defp strip(<<0, rest::binary>>) when byte_size(rest) > 0, do: strip(rest)
  defp strip(b), do: b
end
