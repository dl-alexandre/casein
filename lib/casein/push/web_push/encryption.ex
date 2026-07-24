defmodule Casein.Push.WebPush.Encryption do
  @moduledoc """
  RFC 8291 "Message Encryption for Web Push" (aes128gcm content encoding, per
  RFC 8188). Encrypts a payload for a browser `PushSubscription` using its
  `p256dh` public key and `auth` secret.

  Verified against the published RFC 8291 §5 test vector — see
  `test/casein/push/web_push/encryption_test.exs`. The `:salt` and `:keypair`
  options exist so that test can pin the RFC's ephemeral inputs; production calls
  omit them and generate fresh random values per message (required — a reused
  salt/keypair leaks key material).
  """

  # Record size advertised in the aes128gcm header. Our payloads are a single
  # record well under this, so it's a fixed constant.
  @record_size 4096

  @doc """
  Encrypt `plaintext` for a subscription.

    * `ua_public` — the raw 65-byte uncompressed P-256 public key (decoded
      `p256dh`).
    * `auth_secret` — the raw 16-byte auth secret (decoded `auth`).

  Returns the `aes128gcm` HTTP body binary (header ++ ciphertext ++ tag).
  """
  @spec encrypt(binary(), binary(), binary(), keyword()) :: binary()
  def encrypt(plaintext, ua_public, auth_secret, opts \\ []) do
    salt = Keyword.get(opts, :salt) || :crypto.strong_rand_bytes(16)

    {as_public, as_private} =
      Keyword.get(opts, :keypair) || :crypto.generate_key(:ecdh, :prime256v1)

    # ECDH shared secret between the app-server ephemeral key and the UA key.
    shared = :crypto.compute_key(:ecdh, ua_public, as_private, :prime256v1)

    # RFC 8291 §3.4: fold the UA/app-server keys into the input keying material.
    key_info = "WebPush: info" <> <<0>> <> ua_public <> as_public
    ikm = hkdf(auth_secret, shared, key_info, 32)

    # RFC 8188 content-encryption key + nonce derivation.
    prk = hmac(salt, ikm)
    cek = hkdf_expand(prk, "Content-Encoding: aes128gcm" <> <<0>>, 16)
    nonce = hkdf_expand(prk, "Content-Encoding: nonce" <> <<0>>, 12)

    # Single record: plaintext followed by the last-record delimiter 0x02.
    record = plaintext <> <<2>>

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, record, <<>>, true)

    header =
      salt <>
        <<@record_size::unsigned-big-integer-size(32)>> <>
        <<byte_size(as_public)::unsigned-integer-size(8)>> <>
        as_public

    header <> ciphertext <> tag
  end

  # HKDF (RFC 5869) with a single ≤32-byte output block: extract then one expand.
  defp hkdf(salt, ikm, info, length) do
    salt |> hmac(ikm) |> hkdf_expand(info, length)
  end

  defp hkdf_expand(prk, info, length) do
    :crypto.mac(:hmac, :sha256, prk, info <> <<1>>) |> binary_part(0, length)
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
end
