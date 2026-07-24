defmodule Casein.Push.FCMTokenTest do
  use Casein.TestCase, async: false

  alias Casein.Push.FCMToken

  setup do
    prev = Application.get_env(:casein, FCMToken)
    FCMToken.clear_cache()
    Application.put_env(:casein, :fcm_token_test_pid, self())

    on_exit(fn ->
      FCMToken.clear_cache()
      Application.delete_env(:casein, :fcm_token_test_pid)
      Application.delete_env(:casein, :fcm_token_stub_response)

      if prev,
        do: Application.put_env(:casein, FCMToken, prev),
        else: Application.delete_env(:casein, FCMToken)
    end)

    :ok
  end

  test "uses a directly configured access token" do
    Application.put_env(:casein, FCMToken, access_token: "direct-token")

    assert {:ok, "direct-token"} = FCMToken.access_token()
    refute_receive {:fcm_token_request, _, _, _}
  end

  test "mints and caches an OAuth token from service-account JSON" do
    Application.put_env(:casein, FCMToken,
      service_account_json: Jason.encode!(service_account()),
      http_client: Casein.Push.FCMToken.StubHTTP,
      now_fun: fn -> 1_800_000_000 end
    )

    assert {:ok, "demo-project"} = FCMToken.project_id()
    assert {:ok, "ya29.stub-token"} = FCMToken.access_token()

    assert_receive {:fcm_token_request, "https://oauth2.googleapis.com/token", headers, body},
                   1_000

    assert {"content-type", "application/x-www-form-urlencoded"} in headers

    params = URI.decode_query(body)
    assert params["grant_type"] == "urn:ietf:params:oauth:grant-type:jwt-bearer"

    [encoded_header, encoded_claims, encoded_signature] = String.split(params["assertion"], ".")
    assert byte_size(encoded_signature) > 0

    assert decode_jwt_segment(encoded_header) == %{"alg" => "RS256", "typ" => "JWT"}

    assert decode_jwt_segment(encoded_claims) == %{
             "aud" => "https://oauth2.googleapis.com/token",
             "exp" => 1_800_003_600,
             "iat" => 1_800_000_000,
             "iss" => "firebase-adminsdk@example.iam.gserviceaccount.com",
             "scope" => "https://www.googleapis.com/auth/firebase.messaging",
             "sub" => "firebase-adminsdk@example.iam.gserviceaccount.com"
           }

    assert {:ok, "ya29.stub-token"} = FCMToken.access_token()
    refute_receive {:fcm_token_request, _, _, _}, 100
  end

  test "returns endpoint errors without caching" do
    Application.put_env(:casein, FCMToken,
      service_account_json: Jason.encode!(service_account()),
      http_client: Casein.Push.FCMToken.StubHTTP,
      cache: false
    )

    Application.put_env(
      :casein,
      :fcm_token_stub_response,
      {:ok, %{status: 401, body: %{"error" => "invalid_grant"}}}
    )

    assert {:error, {:token_endpoint_status, 401, %{"error" => "invalid_grant"}}} =
             FCMToken.access_token()
  end

  test "errors clearly when no credential source is configured" do
    Application.put_env(:casein, FCMToken, cache: false)

    assert {:error, :no_service_account} = FCMToken.access_token()
  end

  defp decode_jwt_segment(segment) do
    segment
    |> Base.url_decode64!(padding: false)
    |> Jason.decode!()
  end

  defp service_account do
    %{
      "type" => "service_account",
      "project_id" => "demo-project",
      "private_key_id" => "test-key",
      "private_key" => private_key_pem(),
      "client_email" => "firebase-adminsdk@example.iam.gserviceaccount.com",
      "client_id" => "123",
      "token_uri" => "https://oauth2.googleapis.com/token"
    }
  end

  defp private_key_pem do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
  end
end
