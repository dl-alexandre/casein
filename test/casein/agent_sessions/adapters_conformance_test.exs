defmodule Casein.AgentSessions.AdaptersConformanceTest do
  use ExUnit.Case, async: true

  use Casein.Test.ProviderConformance, adapter: Casein.AgentSessions.Adapters.Codex
  use Casein.Test.ProviderConformance, adapter: Casein.AgentSessions.Adapters.GrokACP

  alias Casein.AgentSessions
  alias Casein.AgentSessions.Adapters

  describe "the driver/observer asymmetry the contract exists for" do
    test "Codex drives and approves; Grok observes and approves but never drives" do
      assert Adapters.Codex.capabilities() == [:drive, :approve]
      assert Adapters.GrokACP.capabilities() == [:observe, :approve]

      assert AgentSessions.capable?(:codex, :drive)
      refute AgentSessions.capable?(:grok_acp, :drive)
    end

    test "send_turn on the observer is refused at the seam, not inside the runtime" do
      assert {:error, {:unsupported, :send_turn}} =
               AgentSessions.send_turn(
                 :grok_acp,
                 %{workspace_id: "ws", attachment_key: "k"},
                 "hi"
               )
    end

    test "the observer does not even export send_turn/3" do
      Code.ensure_loaded!(Adapters.GrokACP)

      refute function_exported?(Adapters.GrokACP, :send_turn, 3),
             "an observer that exports send_turn/3 invites a caller to drive the human's TUI"
    end

    test "both providers can approve" do
      assert AgentSessions.capable?(:codex, :approve)
      assert AgentSessions.capable?(:grok_acp, :approve)
    end
  end

  describe ":interrupt is declared but unimplemented, on purpose" do
    test "no adapter declares it, so the UI can hide the affordance" do
      for id <- AgentSessions.provider_ids() do
        refute AgentSessions.capable?(id, :interrupt),
               "#{id} now claims :interrupt — implement interrupt_turn/2 or drop the claim"
      end
    end

    test "asking for it is a clean contract error" do
      assert {:error, {:unsupported, :interrupt_turn}} =
               AgentSessions.interrupt_turn(:codex, %{runtime_id: "r"}, "turn-1")
    end
  end

  describe "dispatcher" do
    test "unknown providers are rejected by name" do
      assert {:error, {:unknown_provider, :nope}} = AgentSessions.adapter(:nope)
      refute AgentSessions.capable?(:nope, :drive)
    end

    test "provider ids are stable and complete" do
      assert AgentSessions.provider_ids() == [:codex, :grok_acp]
    end
  end
end
