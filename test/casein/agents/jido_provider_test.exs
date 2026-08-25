defmodule Casein.Agents.JidoProviderTest.FakeJidoAI do
  def generate_text(input, opts) do
    send(self(), {:jido_ai_generate_text, input, opts})

    case Application.fetch_env!(:casein, :jido_ai_fake_result) do
      {:raise, message} -> raise message
      result -> result
    end
  end
end

defmodule Casein.Agents.JidoProviderTest.FakeOpenCodeAuth do
  def fetch_api_key do
    send(self(), :open_code_auth_fetch_api_key)

    case Application.fetch_env!(:casein, :jido_auth_fake_result) do
      {:raise, message} -> raise message
      result -> result
    end
  end
end

defmodule Casein.Agents.JidoProviderTest do
  use Casein.TestCase, async: false

  alias Casein.Agents.JidoProvider
  alias Casein.Agents.JidoProvider.{OpenCodeAuth, OpenCodeZen}
  alias Casein.Agents.JidoProviderTest.{FakeJidoAI, FakeOpenCodeAuth}

  setup do
    previous_client = Application.get_env(:casein, :jido_ai_client)
    previous_result = Application.get_env(:casein, :jido_ai_fake_result)
    previous_resolver = Application.get_env(:casein, :jido_auth_resolver)
    previous_auth_result = Application.get_env(:casein, :jido_auth_fake_result)
    previous_xdg_data_home = System.get_env("XDG_DATA_HOME")
    previous_auth_content = System.get_env("OPENCODE_AUTH_CONTENT")

    base =
      Path.join(
        System.tmp_dir!(),
        "jido-provider-#{System.unique_integer([:positive])}"
      )

    auth_path = Path.join([base, "opencode", "auth.json"])
    File.mkdir_p!(Path.dirname(auth_path))

    Application.put_env(:casein, :jido_ai_client, FakeJidoAI)
    Application.put_env(:casein, :jido_ai_fake_result, {:ok, %{text: "ready"}})
    Application.put_env(:casein, :jido_auth_resolver, FakeOpenCodeAuth)
    Application.put_env(:casein, :jido_auth_fake_result, {:ok, "ephemeral-test-key"})
    System.put_env("XDG_DATA_HOME", base)
    System.delete_env("OPENCODE_AUTH_CONTENT")

    on_exit(fn ->
      File.rm_rf!(base)
      restore(:jido_ai_client, previous_client)
      restore(:jido_ai_fake_result, previous_result)
      restore(:jido_auth_resolver, previous_resolver)
      restore(:jido_auth_fake_result, previous_auth_result)
      restore_system_env("XDG_DATA_HOME", previous_xdg_data_home)
      restore_system_env("OPENCODE_AUTH_CONTENT", previous_auth_content)
    end)

    %{auth_path: auth_path}
  end

  test "reads the OpenCode API record fresh for each request", %{auth_path: auth_path} do
    System.put_env("OPENCODE_AUTH_CONTENT", "not-json")
    write_auth!(auth_path, "first-test-key")

    assert {:ok, "first-test-key"} = OpenCodeAuth.fetch_api_key()

    write_auth!(auth_path, "rotated-test-key")

    assert {:ok, "rotated-test-key"} = OpenCodeAuth.fetch_api_key()
  end

  test "auth content has OpenCode precedence and malformed content falls back", %{
    auth_path: auth_path
  } do
    write_auth!(auth_path, "file-test-key")
    content = auth_json("content-test-key")
    System.put_env("OPENCODE_AUTH_CONTENT", content)

    assert {:ok, "content-test-key"} = OpenCodeAuth.fetch_api_key()

    System.put_env("OPENCODE_AUTH_CONTENT", "{")
    assert {:ok, "file-test-key"} = OpenCodeAuth.fetch_api_key()

    System.put_env("OPENCODE_AUTH_CONTENT", "{}")
    assert {:error, :credential_not_found} = OpenCodeAuth.fetch_api_key()
  end

  test "credential failures are stable and contain no source data", %{auth_path: auth_path} do
    source_secret = "must-not-escape"
    System.put_env("OPENCODE_AUTH_CONTENT", "{")
    File.write!(auth_path, ~s({"opencode":{"type":"api","key":""},"note":"#{source_secret}"}))

    assert {:error, :credential_invalid} =
             error =
             OpenCodeAuth.fetch_api_key()

    refute inspect(error) =~ source_secret

    File.write!(auth_path, ~s({"opencode":{"type":"oauth","access":"#{source_secret}"}}))

    assert {:error, :credential_type_unsupported} =
             error =
             OpenCodeAuth.fetch_api_key()

    refute inspect(error) =~ source_secret
  end

  test "Zen generation fixes routing and passes the runtime key only per request" do
    api_key = "ephemeral-test-key"

    assert {:ok, %{text: "ready"}} =
             OpenCodeZen.generate("inspect the change",
               auth_path: "/caller/must/not/redirect/credentials.json",
               auth_content: auth_json("caller-key-must-not-win"),
               api_key: "caller-key-must-not-win",
               model: "openai:wrong-model",
               base_url: "https://wrong.invalid/v1",
               max_tokens: 512,
               unknown_option: :discarded
             )

    assert_received :open_code_auth_fetch_api_key
    assert_received {:jido_ai_generate_text, "inspect the change", opts}
    assert opts[:api_key] == api_key
    assert opts[:max_tokens] == 512
    assert opts[:model] == OpenCodeZen.model_spec()
    refute Keyword.has_key?(opts, :base_url)
    refute Keyword.has_key?(opts, :unknown_option)
  end

  test "the model spec deterministically selects Zen's Responses route" do
    assert {:ok,
            %{
              surface: :openai_responses,
              route: %{method: :post, path: "/responses"}
            }} = ReqLLM.plan(OpenCodeZen.model_spec(), :chat, [])
  end

  test "upstream failures are discarded before crossing the adapter boundary" do
    api_key = "redacted-test-key"
    Application.put_env(:casein, :jido_auth_fake_result, {:ok, api_key})

    Application.put_env(
      :casein,
      :jido_ai_fake_result,
      {:error, %{request: %{headers: %{authorization: "Bearer #{api_key}"}}}}
    )

    assert {:error,
            %{
              error: :provider_unavailable,
              reason: :request_failed,
              retryable: true,
              provider: "opencode",
              model: "opencode/grok-4.6"
            }} =
             error =
             JidoProvider.generate("fail safely")

    refute inspect(error) =~ api_key

    Application.put_env(:casein, :jido_ai_fake_result, {:raise, "request carried #{api_key}"})

    assert {:error, %{reason: :request_failed, retryable: true}} =
             raised_error =
             JidoProvider.generate("fail safely after raise")

    refute inspect(raised_error) =~ api_key
  end

  test "missing credentials fail without invoking Jido.AI" do
    Application.put_env(:casein, :jido_auth_fake_result, {:error, :credential_not_found})

    assert {:error,
            %{
              error: :provider_unavailable,
              reason: :credential_not_found,
              retryable: false
            }} = OpenCodeZen.generate("no credential")

    assert_received :open_code_auth_fetch_api_key
    refute_received {:jido_ai_generate_text, _, _}
  end

  test "credential resolver failures cannot expose source content" do
    source_secret = "resolver-secret-must-not-escape"
    Application.put_env(:casein, :jido_auth_fake_result, {:raise, source_secret})

    assert {:error, %{reason: :credential_unreadable, retryable: false}} =
             error =
             OpenCodeZen.generate("fail before provider call")

    refute inspect(error) =~ source_secret
    refute_received {:jido_ai_generate_text, _, _}
  end

  test "provider metadata is secret-free" do
    assert %{
             provider: "opencode",
             model: "opencode/grok-4.6",
             api_model: "grok-4.6",
             base_url: "https://opencode.ai/zen/v1",
             wire_protocol: :openai_responses,
             credential_source: :opencode_runtime
           } = JidoProvider.info()
  end

  defp write_auth!(path, key) do
    File.write!(path, auth_json(key))
    File.chmod!(path, 0o600)
  end

  defp auth_json(key), do: Jason.encode!(%{"opencode" => %{"type" => "api", "key" => key}})

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, value), do: Application.put_env(:casein, key, value)

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
