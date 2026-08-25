defmodule CaseinWeb.SuperadminHandoffTest do
  use ExUnit.Case, async: false

  alias CaseinWeb.SuperadminHandoff

  setup do
    previous_secret = Application.get_env(:casein, :superadmin_handoff_secret)
    previous_domain = Application.get_env(:casein, :forward_auth_email_domain)

    Application.put_env(:casein, :superadmin_handoff_secret, "handoff-test-secret")
    Application.put_env(:casein, :forward_auth_email_domain, "milcgroup.com")

    on_exit(fn ->
      restore_app_env(:superadmin_handoff_secret, previous_secret)
      restore_app_env(:forward_auth_email_domain, previous_domain)
    end)

    :ok
  end

  test "verifies a signed superadmin handoff" do
    token = sign_claims(claims(exp: now() + 60, iat: now() - 1))

    assert {:ok, verified} = SuperadminHandoff.verify(token)
    assert verified["email"] == "operator@milcgroup.com"
    assert verified["workspace_id"] == "workspace-123"
    assert verified["session_id"] == "session-123"
  end

  test "rejects a tampered handoff" do
    token = sign_claims(claims()) <> "tampered"

    assert {:error, :invalid_handoff} = SuperadminHandoff.verify(token)
  end

  test "rejects an expired handoff" do
    token = sign_claims(claims(exp: now() - 1, iat: now() - 61))

    assert {:error, :invalid_handoff} = SuperadminHandoff.verify(token)
  end

  test "rejects an email outside the configured internal domain" do
    token = sign_claims(claims(email: "operator@example.com"))

    assert {:error, :invalid_handoff} = SuperadminHandoff.verify(token)
  end

  test "verifies an actor assertion separately from a browser handoff" do
    token = sign_claims(claims(kind: "onebackend_superadmin_actor"))

    assert {:ok, verified} = SuperadminHandoff.verify_actor(token)
    assert verified["email"] == "operator@milcgroup.com"
    assert verified["workspace_id"] == "workspace-123"
    assert {:error, :invalid_handoff} = SuperadminHandoff.verify(token)
  end

  test "does not accept a browser handoff as an actor assertion" do
    token = sign_claims(claims())

    assert {:error, :invalid_handoff} = SuperadminHandoff.verify_actor(token)
  end

  defp claims(overrides \\ []) do
    Map.merge(
      %{
        "kind" => "onebackend_superadmin",
        "email" => "operator@milcgroup.com",
        "workspace_id" => "workspace-123",
        "session_id" => "session-123",
        "tmux_session" => "tmux-session-123",
        "iat" => now() - 1,
        "exp" => now() + 60
      },
      Map.new(overrides)
    )
  end

  defp sign_claims(claims) do
    payload = claims |> Jason.encode!() |> Base.url_encode64(padding: false)
    signature = :crypto.mac(:hmac, :sha256, "handoff-test-secret", payload)
    payload <> "." <> Base.url_encode64(signature, padding: false)
  end

  defp now, do: System.system_time(:second)

  defp restore_app_env(key, nil), do: Application.delete_env(:casein, key)
  defp restore_app_env(key, value), do: Application.put_env(:casein, key, value)
end
