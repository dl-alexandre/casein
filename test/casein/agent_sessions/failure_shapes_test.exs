defmodule Casein.AgentSessions.FailureShapesTest do
  @moduledoc """
  Bad input must fail as a *value*, not as a crash.

  These are review findings, not speculation. A cross-provider approval UI holds
  one `PendingRequest` list spanning both providers, so it will hand whatever
  `request_id` it received back to whichever adapter owns it. Grok's ids are
  `String.t() | integer()`; Codex's `ApprovalBroker.resolve/3` guards
  `when is_binary(approval_id)`. Without validation an integer id raised
  `FunctionClauseError` out of the adapter instead of returning an error.
  """
  use ExUnit.Case, async: true

  alias Casein.AgentSessions
  alias Casein.AgentSessions.Adapters
  alias Casein.AgentSessions.Provider.PendingRequest

  describe "request_id validation (Codex)" do
    test "a non-binary request_id is an error value, not a FunctionClauseError" do
      for bad <- [12_345, nil, :atom_id, %{}] do
        result =
          Adapters.Codex.respond_to_request(
            %{runtime_id: "runtime-x"},
            bad,
            {:decision, :accept}
          )

        assert {:error, {:invalid_request_id, ^bad}} = result
      end
    end

    test "an empty binary is rejected too" do
      assert {:error, {:invalid_request_id, ""}} =
               Adapters.Codex.respond_to_request(%{runtime_id: "r"}, "", {:decision, :accept})
    end

    test "validation runs before the runtime lookup" do
      # A bad id on a runtime that is not running must report the id problem,
      # not the missing runtime — otherwise the caller fixes the wrong thing.
      assert {:error, {:invalid_request_id, 7}} =
               Adapters.Codex.respond_to_request(%{runtime_id: "nope"}, 7, {:decision, :accept})
    end
  end

  describe "decision shape mismatches" do
    test "Codex refuses an option-list choice instead of guessing a policy" do
      assert {:error, {:unsupported_decision_shape, :choice}} =
               Adapters.Codex.respond_to_request(%{runtime_id: "r"}, "req-1", {:choice, "opt-a"})
    end

    test "Grok refuses a policy decision it has no vocabulary for" do
      assert {:error, {:unsupported_decision_shape, :accept_for_session}} =
               Adapters.GrokACP.respond_to_request(
                 %{workspace_id: "ws", attachment_key: "default"},
                 "req-1",
                 {:decision, :accept_for_session}
               )
    end

    test "both refuse a malformed decision" do
      assert {:error, {:invalid_decision, :garbage}} =
               Adapters.Codex.respond_to_request(%{runtime_id: "r"}, "req-1", :garbage)

      assert {:error, {:invalid_decision, :garbage}} =
               Adapters.GrokACP.respond_to_request(
                 %{workspace_id: "ws", attachment_key: "default"},
                 "req-1",
                 :garbage
               )
    end
  end

  describe "PendingRequest rejects an unresolvable row" do
    test "a nil request_id raises rather than rendering an unanswerable approval" do
      assert_raise ArgumentError, ~r/request_id is required/, fn ->
        PendingRequest.new(%{provider_id: :codex, request_id: nil, title: "x"})
      end
    end

    test "a blank title falls back instead of rendering an empty row" do
      request = PendingRequest.new(%{provider_id: :codex, request_id: "r1", title: "   "})
      assert request.title == PendingRequest.default_title()
    end

    test "empty options normalize to nil so the UI reads it as a policy provider" do
      request =
        PendingRequest.new(%{provider_id: :codex, request_id: "r1", title: "t", options: []})

      assert request.options == nil
      refute PendingRequest.option_list?(request)
    end
  end

  describe "dispatcher errors are values" do
    test "an unknown provider does not raise" do
      assert {:error, {:unknown_provider, :nope}} =
               AgentSessions.respond_to_request(:nope, %{}, "r", {:decision, :accept})
    end

    test "a malformed session ref is rejected, not matched loosely" do
      assert {:error, :invalid_session_ref} = Adapters.Codex.status(:garbage)
      assert {:error, :invalid_session_ref} = Adapters.GrokACP.status(:garbage)
    end
  end
end
