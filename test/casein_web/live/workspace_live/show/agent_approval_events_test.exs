defmodule CaseinWeb.WorkspaceLive.Show.AgentApprovalEventsTest.Provider do
  @behaviour Casein.AgentSessions.Provider

  @impl true
  def capabilities, do: [:approve]

  @impl true
  def start_session(_spec), do: {:error, :not_used}

  @impl true
  def stop_session(_session_ref), do: :ok

  @impl true
  def status(_session_ref), do: {:ok, %{}}

  @impl true
  def respond_to_request(session_ref, request_id, decision) do
    send(
      session_ref.test_pid,
      {:approval_response, session_ref.provider_id, request_id, decision}
    )

    Map.get(session_ref, :result, {:ok, %{}})
  end

  @impl true
  def pending_requests(_session_ref), do: {:ok, []}
end

defmodule CaseinWeb.WorkspaceLive.Show.AgentApprovalEventsTest do
  use Casein.TestCase, async: false

  alias Casein.AgentSessions.Provider.PendingRequest
  alias Casein.Audit
  alias CaseinWeb.WorkspaceLive.Show.AgentApprovalEvents
  alias CaseinWeb.WorkspaceLive.Show.AgentApprovalEventsTest.Provider

  setup do
    providers = Application.fetch_env!(:casein, :agent_session_providers)
    Audit.clear()
    Application.put_env(:casein, :agent_session_providers, %{codex: Provider, grok_acp: Provider})

    on_exit(fn ->
      Audit.clear()
      Application.put_env(:casein, :agent_session_providers, providers)
    end)
  end

  defp socket(requests) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        workspace: %{id: "ws-approval-events"},
        current_user: %{id: "actor-1"},
        codex_pending_requests: Enum.filter(requests, &(&1.provider_id == :codex)),
        grok_permission_requests: Enum.filter(requests, &(&1.provider_id == :grok_acp)),
        codex_selected_thread_id: nil
      }
    }
  end

  defp request(provider_id, options \\ nil, session_attrs \\ %{}) do
    PendingRequest.new(%{
      provider_id: provider_id,
      session_ref: Map.merge(%{provider_id: provider_id, test_pid: self()}, session_attrs),
      request_id: "request-1",
      title: "Needs approval",
      options: options
    })
  end

  test "merged handler sends a provider option as a tagged choice" do
    pending =
      request(:grok_acp, [%{id: "allow-once", label: "Allow once", kind: :allow_once}])

    assert {:noreply, returned} =
             AgentApprovalEvents.handle_event(
               "agent_approval:respond",
               %{
                 "provider-id" => "grok_acp",
                 "request-id" => "request-1",
                 "decision-kind" => "choice",
                 "option-id" => "allow-once"
               },
               socket([pending])
             )

    assert_receive {:approval_response, :grok_acp, "request-1", {:choice, "allow-once"}}
    assert returned.assigns.flash["info"] == "Agent approval response sent."
  end

  test "merged handler sends a policy decision in the tagged decision shape" do
    pending = request(:codex)

    assert {:noreply, _returned} =
             AgentApprovalEvents.handle_event(
               "agent_approval:respond",
               %{
                 "provider-id" => "codex",
                 "request-id" => "request-1",
                 "decision-kind" => "decline"
               },
               socket([pending])
             )

    assert_receive {:approval_response, :codex, "request-1", {:decision, :decline}}

    assert [%{action: "agent.approval_decided", target_type: "agent_approval"} = audit] =
             Audit.list()

    assert audit.metadata.provider_id == :codex
  end

  test "Codex exec-policy amendments reach respond_to_request/4 as a decision tuple" do
    pending = request(:codex)

    assert {:noreply, _returned} =
             AgentApprovalEvents.handle_event(
               "agent_approval:respond",
               %{
                 "provider-id" => "codex",
                 "request-id" => "request-1",
                 "decision-kind" => "execpolicy_amendment",
                 "execpolicy-amendment" => "git status\n\nmix test"
               },
               socket([pending])
             )

    assert_receive {:approval_response, :codex, "request-1",
                    {:decision, {:accept_with_execpolicy_amendment, ["git status", "mix test"]}}}
  end

  test "a second Grok response is benign when the first responder already won" do
    pending =
      request(:grok_acp, [%{id: "allow", label: "Allow", kind: nil}], %{
        result: {:error, :permission_not_found}
      })

    assert {:noreply, returned} =
             AgentApprovalEvents.handle_event(
               "agent_approval:respond",
               %{
                 "provider-id" => "grok_acp",
                 "request-id" => "request-1",
                 "decision-kind" => "choice",
                 "option-id" => "allow"
               },
               socket([pending])
             )

    assert returned.assigns.flash["info"] == "That request was already resolved."
    refute Map.has_key?(returned.assigns.flash, "error")
  end

  test "invalid and stale responses are rejected without dispatch" do
    pending = request(:codex)

    assert {:noreply, invalid} =
             AgentApprovalEvents.handle_event(
               "agent_approval:respond",
               %{
                 "provider-id" => "codex",
                 "request-id" => "request-1",
                 "decision-kind" => "choice",
                 "option-id" => "invented"
               },
               socket([pending])
             )

    assert invalid.assigns.flash["error"] == "That approval response was invalid."
    refute_receive {:approval_response, _, _, _}

    assert {:noreply, stale} =
             AgentApprovalEvents.handle_event(
               "agent_approval:respond",
               %{
                 "provider-id" => "codex",
                 "request-id" => "missing",
                 "decision-kind" => "accept"
               },
               socket([pending])
             )

    assert stale.assigns.flash["info"] == "That request was already resolved."
  end
end
