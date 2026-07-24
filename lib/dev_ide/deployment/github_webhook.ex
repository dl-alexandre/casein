defmodule Casein.Deployment.GithubWebhook do
  @moduledoc """
  GitHub push-webhook verification and push-event filtering.

  Validates `X-Hub-Signature-256` against the raw request body and accepts only
  non-deleted pushes to the configured deploy branch on the expected repository.
  """

  alias Casein.Deployment.Drift

  @signature_prefix "sha256="

  @doc "Returns the configured webhook secret, if any."
  @spec configured_secret() :: String.t() | nil
  def configured_secret do
    config(:github_webhook_secret) ||
      blank_to_nil(System.get_env("DEVIDE_DEPLOY_WEBHOOK_SECRET"))
  end

  @doc "Verifies the GitHub HMAC signature for a raw JSON body."
  @spec verify_signature(binary(), binary() | nil, binary()) ::
          :ok | {:error, :missing_signature | :invalid_signature}
  def verify_signature(_raw_body, nil, _secret), do: {:error, :missing_signature}
  def verify_signature(_raw_body, "", _secret), do: {:error, :missing_signature}

  def verify_signature(raw_body, signature, secret)
      when is_binary(raw_body) and is_binary(signature) and is_binary(secret) do
    expected =
      @signature_prefix <>
        (:crypto.mac(:hmac, :sha256, secret, raw_body) |> Base.encode16(case: :lower))

    if secure_compare?(signature, expected), do: :ok, else: {:error, :invalid_signature}
  end

  @doc "Returns `:ok` when a push payload should trigger the deploy poller."
  @spec master_push?(map()) :: :ok | {:ignore, String.t()}
  def master_push?(%{"deleted" => true}), do: {:ignore, "branch_deleted"}

  def master_push?(payload) when is_map(payload) do
    branch = Drift.branch()
    expected_ref = "refs/heads/#{branch}"

    with {:ok, ref} <- fetch_ref(payload),
         :ok <- assert_ref(ref, expected_ref),
         :ok <- assert_repository(payload) do
      :ok
    else
      {:ignore, reason} -> {:ignore, reason}
      {:error, reason} -> {:ignore, reason}
    end
  end

  def master_push?(_payload), do: {:ignore, "invalid_payload"}

  defp fetch_ref(%{"ref" => ref}) when is_binary(ref) and ref != "", do: {:ok, ref}
  defp fetch_ref(_payload), do: {:error, "missing_ref"}

  defp assert_ref(ref, expected_ref) when ref == expected_ref, do: :ok
  defp assert_ref(ref, _expected_ref), do: {:ignore, "non_deploy_branch:#{ref}"}

  defp assert_repository(%{"repository" => %{"full_name" => full_name}})
       when is_binary(full_name) do
    case expected_repo() do
      nil -> :ok
      ^full_name -> :ok
      expected -> {:ignore, "unexpected_repo:#{full_name},expected:#{expected}"}
    end
  end

  defp assert_repository(_payload), do: :ok

  defp expected_repo do
    config(:github_repo) || blank_to_nil(System.get_env("DEVIDE_GITHUB_REPO"))
  end

  defp secure_compare?(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and Plug.Crypto.secure_compare(left, right)
  end

  defp secure_compare?(_, _), do: false

  defp blank_to_nil(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp blank_to_nil(_), do: nil

  defp config(key) do
    :dev_ide
    |> Application.get_env(:deployment, [])
    |> Keyword.get(key)
  end
end
