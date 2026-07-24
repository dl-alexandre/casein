defmodule CaseinWeb.Plugs.ApiAuthOrchestratorTest do
  @moduledoc """
  DB-backed orchestrator token resolution in ApiAuth: a self-serve minted token
  resolves to a non-global `{:orchestrator, subject}` scope that traverses
  (leaves `:api_workspace_id` unassigned), and stops working once revoked.
  """
  use Casein.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Casein.Agents.OrchestratorTokens
  alias CaseinWeb.Plugs.ApiAuth

  setup do
    prev_api_token = Application.get_env(:dev_ide, :api_token)
    # A configured global token keeps the plaintext path non-empty (realistic);
    # the orchestrator token below is a different secret resolved via the DB.
    Application.put_env(:dev_ide, :api_token, "env-global-token")
    on_exit(fn -> restore(:api_token, prev_api_token) end)
    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, val), do: Application.put_env(:dev_ide, key, val)

  defp user, do: %{id: "alice", username: "alice", email: "alice@example.com", role: :user}

  defp call(token, path \\ "/api/terminals/mcp") do
    conn(:post, path)
    |> put_req_header("authorization", "Bearer " <> token)
    |> ApiAuth.call([])
  end

  test "a minted orchestrator token resolves to a non-global traverse scope" do
    {:ok, raw, _record} = OrchestratorTokens.create_for_subject(user())

    conn = call(raw)

    refute conn.halted
    assert conn.assigns[:api_token_scope] == {:orchestrator, "alice"}
    assert conn.assigns[:api_token_subject] == "alice"
    # traverse: no workspace pinned at the HTTP gate (per-call confinement in controllers)
    refute Map.has_key?(conn.assigns, :api_workspace_id)
  end

  test "orchestrator scope is distinct from :global (so tool-calls are not gate-rejected)" do
    {:ok, raw, _record} = OrchestratorTokens.create_for_subject(user())
    assert {:orchestrator, _} = call(raw).assigns[:api_token_scope]
    # the env global token still resolves to :global
    assert call("env-global-token").assigns[:api_token_scope] == :global
  end

  test "a revoked orchestrator token is rejected with 401" do
    {:ok, raw, record} = OrchestratorTokens.create_for_subject(user())
    {:ok, _} = OrchestratorTokens.revoke(record.id, user())

    conn = call(raw)
    assert conn.halted
    assert conn.status == 401
  end
end
