defmodule Casein.AgentSessions.Adapters.Codex do
  @moduledoc """
  `Casein.AgentSessions.Provider` over the existing Codex stack.

  Deliberately thin. `lib/casein/codex/` (19 modules: `AppServer`, `JsonRpc`,
  `Protocol`, `EventRouter`, `EventHub`, `ApprovalBroker`, `Runtime`,
  `RuntimeSupervisor`, `Store` + Ecto adapter) is not moved or rewritten — this
  wraps it. `Runtime` keeps supervising `EventRouter`, `ApprovalBroker` and
  `AppServer` per home/worktree/security context; the adapter only addresses a
  runtime, it does not become one.

  Capabilities: `[:drive, :approve]`. Codex owns the thread and submits turns,
  and `ApprovalBroker` is the single runtime-local authority for approvals. No
  `:interrupt` — nothing in `lib/casein/codex/` can cancel an in-flight turn
  today (`protocol.ex` only maps an *inbound* `"interrupted"` status, and the
  broker's `:cancel` is approval-scoped).

  `workspace_mode` is passed through untouched. It is the input to
  `AppServer.security_defaults/1`, which maps it to `approvalPolicy` and
  `sandbox` — `:unrestricted` means `danger-full-access`. Dropping or defaulting
  it here would silently widen the sandbox, so it rides on `SessionSpec` as a
  named field and every mapping is pinned in `app_server_test.exs`.
  """

  @behaviour Casein.AgentSessions.Provider

  alias Casein.AgentSessions.Provider.{PendingRequest, SessionSpec}
  alias Casein.Codex.{ApprovalBroker, AppServer, Runtime}

  @provider_id :codex

  @impl true
  def capabilities, do: [:drive, :approve]

  @impl true
  def start_session(%SessionSpec{} = spec) do
    with {:ok, runtime_id} <- require_runtime_id(spec),
         {:ok, server} <- app_server(runtime_id),
         :ok <- AppServer.await_ready(server),
         {:ok, thread} <- open_thread(server, spec) do
      {:ok,
       %{
         provider_id: @provider_id,
         runtime_id: runtime_id,
         thread_id: Map.get(thread, :thread_id) || Map.get(thread, "threadId"),
         session_id: Map.get(thread, :session_id) || Map.get(thread, "sessionId")
       }}
    end
  end

  @impl true
  def stop_session(%{runtime_id: runtime_id}) when is_binary(runtime_id) do
    # Idempotent by contract: a runtime that is already gone is a success, not an
    # error — callers tearing down twice must not have to special-case it.
    case Casein.Codex.RuntimeSupervisor.stop_runtime(runtime_id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      other -> other
    end
  end

  def stop_session(_session_ref), do: {:error, :invalid_session_ref}

  @impl true
  def status(%{runtime_id: runtime_id} = ref) when is_binary(runtime_id) do
    with {:ok, server} <- app_server(runtime_id) do
      snapshot = AppServer.status(server)

      {:ok,
       %{
         provider_id: @provider_id,
         session_ref: ref,
         status: Map.get(snapshot, :status),
         security: Map.get(snapshot, :security),
         raw: snapshot
       }}
    end
  end

  def status(_session_ref), do: {:error, :invalid_session_ref}

  @impl true
  def send_turn(%{runtime_id: runtime_id, thread_id: thread_id}, input, opts)
      when is_binary(runtime_id) and is_binary(thread_id) do
    with {:ok, server} <- app_server(runtime_id) do
      params = Keyword.get(opts, :params, %{})
      AppServer.start_turn(server, thread_id, input, params)
    end
  end

  def send_turn(_session_ref, _input, _opts), do: {:error, :invalid_session_ref}

  @impl true
  def respond_to_request(%{runtime_id: runtime_id}, request_id, decision)
      when is_binary(runtime_id) do
    with {:ok, broker} <- broker(runtime_id),
         {:ok, resolved} <- to_broker_decision(decision) do
      ApprovalBroker.resolve(broker, request_id, resolved)
    end
  end

  def respond_to_request(_session_ref, _request_id, _decision), do: {:error, :invalid_session_ref}

  @impl true
  def pending_requests(%{runtime_id: runtime_id} = ref) when is_binary(runtime_id) do
    with {:ok, broker} <- broker(runtime_id) do
      requests =
        broker
        |> ApprovalBroker.pending()
        |> Enum.map(&to_pending_request(&1, ref))

      {:ok, requests}
    end
  end

  def pending_requests(_session_ref), do: {:error, :invalid_session_ref}

  # Codex has no option list — the operator picks a policy decision. Preserve the
  # full six-kind vocabulary; flattening to accept/decline would make the
  # execpolicy and network-policy amendments unreachable, which is exactly the
  # gap the current codex_events.ex UI has.
  defp to_broker_decision({:decision, decision}), do: {:ok, decision}

  defp to_broker_decision({:choice, _option_id}),
    do: {:error, {:unsupported_decision_shape, :choice}}

  defp to_broker_decision(other), do: {:error, {:invalid_decision, other}}

  defp to_pending_request(approval, session_ref) do
    PendingRequest.new(%{
      provider_id: @provider_id,
      session_ref: session_ref,
      request_id: Map.get(approval, :id) || Map.get(approval, :request_id),
      title: Map.get(approval, :title) || "Codex needs approval to continue",
      detail: Map.get(approval, :detail) || Map.get(approval, :command),
      # nil options marks a policy provider: the UI renders accept/decline plus
      # amendments rather than a provider-supplied list.
      options: nil,
      requested_at: Map.get(approval, :requested_at),
      metadata: Map.get(approval, :metadata, %{})
    })
  end

  defp open_thread(server, %SessionSpec{} = spec) do
    if SessionSpec.resume?(spec) do
      AppServer.resume_thread(server, spec.session_id, thread_params(spec))
    else
      AppServer.start_thread(server, thread_params(spec))
    end
  end

  defp thread_params(%SessionSpec{opts: opts}), do: Keyword.get(opts, :params, %{})

  defp require_runtime_id(%SessionSpec{runtime_id: runtime_id})
       when is_binary(runtime_id) and runtime_id != "",
       do: {:ok, runtime_id}

  defp require_runtime_id(%SessionSpec{}), do: {:error, :missing_runtime_id}

  defp app_server(runtime_id), do: component(runtime_id, :app_server)
  defp broker(runtime_id), do: component(runtime_id, :approval_broker)

  defp component(runtime_id, component) do
    case Runtime.whereis_component(runtime_id, component) do
      pid when is_pid(pid) -> {:ok, pid}
      _other -> {:error, {:runtime_not_running, runtime_id, component}}
    end
  end
end
