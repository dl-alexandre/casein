defmodule CaseinWeb.SuperadminHandoff do
  @moduledoc """
  Verifies the short-lived browser handoff minted by OneBackend.

  The handoff is intentionally a signed capability, not a second login system:
  OneBackend can mint it only after its superadmin session is authenticated, and
  Casein accepts it only for the configured internal email domain.
  """

  @max_lifetime_seconds 120

  @spec verify(String.t()) :: {:ok, map()} | {:error, atom()}
  def verify(token) when is_binary(token) and token != "" do
    with [encoded_payload, encoded_signature] <- String.split(token, ".", parts: 2),
         {:ok, signature} <- Base.url_decode64(encoded_signature, padding: false),
         secret when is_binary(secret) <- secret(),
         expected <- :crypto.mac(:hmac, :sha256, secret, encoded_payload),
         true <- secure_compare?(signature, expected),
         {:ok, payload_json} <- Base.url_decode64(encoded_payload, padding: false),
         {:ok, claims} <- Jason.decode(payload_json),
         :ok <- validate_claims(claims) do
      {:ok, claims}
    else
      _ -> {:error, :invalid_handoff}
    end
  end

  def verify(_), do: {:error, :invalid_handoff}

  @spec verify_actor(String.t()) :: {:ok, map()} | {:error, atom()}
  def verify_actor(token) when is_binary(token) and token != "" do
    with [encoded_payload, encoded_signature] <- String.split(token, ".", parts: 2),
         {:ok, signature} <- Base.url_decode64(encoded_signature, padding: false),
         secret when is_binary(secret) <- secret(),
         expected <- :crypto.mac(:hmac, :sha256, secret, encoded_payload),
         true <- secure_compare?(signature, expected),
         {:ok, payload_json} <- Base.url_decode64(encoded_payload, padding: false),
         {:ok, claims} <- Jason.decode(payload_json),
         :ok <- validate_actor_claims(claims) do
      {:ok, claims}
    else
      _ -> {:error, :invalid_handoff}
    end
  end

  def verify_actor(_), do: {:error, :invalid_handoff}

  @spec email_domain() :: String.t() | nil
  def email_domain do
    Application.get_env(:casein, :forward_auth_email_domain) ||
      System.get_env("CASEIN_FORWARD_AUTH_EMAIL_DOMAIN")
  end

  defp validate_claims(%{
         "kind" => "onebackend_superadmin",
         "email" => email,
         "workspace_id" => workspace_id,
         "session_id" => session_id,
         "tmux_session" => _tmux_session,
         "exp" => exp,
         "iat" => iat
       })
       when is_binary(email) and is_binary(workspace_id) and workspace_id != "" and
              is_binary(session_id) and session_id != "" and is_integer(exp) and is_integer(iat) do
    now = System.system_time(:second)

    cond do
      not valid_email?(email) -> {:error, :invalid_email}
      exp < now -> {:error, :expired}
      iat > now + 30 -> {:error, :issued_in_the_future}
      exp - iat > @max_lifetime_seconds -> {:error, :lifetime_too_long}
      true -> :ok
    end
  end

  defp validate_claims(_), do: {:error, :invalid_claims}

  defp validate_actor_claims(%{
         "kind" => "onebackend_superadmin_actor",
         "email" => email,
         "workspace_id" => workspace_id,
         "exp" => exp,
         "iat" => iat
       })
       when is_binary(email) and is_binary(workspace_id) and workspace_id != "" and
              is_integer(exp) and is_integer(iat) do
    now = System.system_time(:second)

    cond do
      not valid_email?(email) -> {:error, :invalid_email}
      exp < now -> {:error, :expired}
      iat > now + 30 -> {:error, :issued_in_the_future}
      exp - iat > @max_lifetime_seconds -> {:error, :lifetime_too_long}
      true -> :ok
    end
  end

  defp validate_actor_claims(_), do: {:error, :invalid_claims}

  defp valid_email?(email) do
    normalized = String.downcase(String.trim(email))

    case email_domain() do
      domain when is_binary(domain) and domain != "" ->
        domain = String.downcase(String.trim(domain))
        String.contains?(normalized, "@") and String.ends_with?(normalized, "@" <> domain)

      _ ->
        false
    end
  end

  defp secret do
    Application.get_env(:casein, :superadmin_handoff_secret) ||
      System.get_env("CASEIN_HANDOFF_SECRET") ||
      System.get_env("CASEIN_API_TOKEN")
  end

  defp secure_compare?(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and Plug.Crypto.secure_compare(left, right)
  end

  defp secure_compare?(_, _), do: false
end
