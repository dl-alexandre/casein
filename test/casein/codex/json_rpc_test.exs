defmodule Casein.Codex.JsonRpcTest do
  use ExUnit.Case, async: true

  alias Casein.Codex.JsonRpc

  test "encodes App Server requests without a jsonrpc header" do
    encoded = JsonRpc.encode_request(10, "thread/start", %{"cwd" => "/workspace"})

    assert String.ends_with?(encoded, "\n")
    refute encoded =~ "jsonrpc"

    assert {:ok, {:request, 10, "thread/start", %{"cwd" => "/workspace"}}} =
             JsonRpc.decode(encoded)
  end

  test "classifies notifications, results, errors, and server requests" do
    assert {:ok, {:notification, "turn/started", %{"threadId" => "thr"}}} =
             JsonRpc.decode(~s({"method":"turn/started","params":{"threadId":"thr"}}))

    assert {:ok, {:response, "req-1", %{"ok" => true}}} =
             JsonRpc.decode(~s({"id":"req-1","result":{"ok":true}}))

    assert {:ok, {:error_response, 4, %{"code" => -32_601, "message" => "missing"}}} =
             JsonRpc.decode(~s({"id":4,"error":{"code":-32601,"message":"missing"}}))

    assert {:ok, {:request, 8, "item/commandExecution/requestApproval", %{"itemId" => "i"}}} =
             JsonRpc.decode(
               ~s({"id":8,"method":"item/commandExecution/requestApproval","params":{"itemId":"i"}})
             )
  end

  test "rejects malformed JSON and invalid message shapes" do
    assert {:error, :invalid_json} = JsonRpc.decode("{")
    assert {:error, :invalid_message} = JsonRpc.decode("[]")
    assert {:error, :invalid_message} = JsonRpc.decode(~s({"method":"turn/started","params":[]}))
  end
end
