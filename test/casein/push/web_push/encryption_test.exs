defmodule Casein.Push.WebPush.EncryptionTest do
  use ExUnit.Case, async: true

  alias Casein.Push.WebPush.Encryption

  defp d(s), do: Base.url_decode64!(s, padding: false)

  test "reproduces the RFC 8291 §5 published test vector" do
    # https://www.rfc-editor.org/rfc/rfc8291#section-5 — the canonical worked
    # example. Pinning the RFC's salt + application-server keypair lets us verify
    # the whole aes128gcm pipeline (ECDH, HKDF, AES-128-GCM, header framing)
    # against an independent, authoritative reference — the one piece that can't
    # be checked by delivering to a real browser.
    plaintext = "When I grow up, I want to be a watermelon"

    ua_public =
      d("BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4")

    auth_secret = d("BTBZMqHH6r4Tts7J_aSIgg")
    salt = d("DGv6ra1nlYgDCS1FRnbzlw")

    as_public =
      d("BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8")

    as_private = d("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw")

    expected =
      "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"

    body =
      Encryption.encrypt(plaintext, ua_public, auth_secret,
        salt: salt,
        keypair: {as_public, as_private}
      )

    assert Base.url_encode64(body, padding: false) == expected
  end

  test "fresh calls produce distinct salts/keys (no reuse)" do
    ua_public =
      d("BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4")

    auth_secret = d("BTBZMqHH6r4Tts7J_aSIgg")
    a = Encryption.encrypt("hi", ua_public, auth_secret)
    b = Encryption.encrypt("hi", ua_public, auth_secret)
    # The 16-byte salt header prefix must differ between messages.
    assert binary_part(a, 0, 16) != binary_part(b, 0, 16)
  end
end
