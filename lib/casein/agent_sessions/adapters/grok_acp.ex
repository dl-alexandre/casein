defmodule Casein.AgentSessions.Adapters.GrokACP do
  @moduledoc """
  `Casein.AgentSessions.Provider` over the existing Grok ACP observer.

  Capabilities: `[:observe, :approve]`. **No `:drive`.**

  That omission is the point, not a gap. `Casein.AgentSessions.GrokACP` is a
  supervised *observer*: it performs ACP initialization, then loads the same
  session as the human's TUI so it becomes a leader subscriber and can project
  tool, plan, and permission events into `Casein.Agents.Activity` without
  scraping terminal output. The human drives the TUI; this client must never
  submit turns.

  So `send_turn/3` is simply not exported. `Casein.AgentSessions` refuses it at
  the seam with `{:error, {:unsupported, :send_turn}}` — a contract outcome
  rather than a crash inside a runtime that was never asked to drive.

  ## First response wins

  The leader broadcasts each permission request to every subscriber and the first
  response wins; `Attachments` mediates. Multi-viewer is normal here, so a second
  responder gets `{:error, :permission_not_found}`, which means "someone else
  already answered" — not a failure to surface.
  """

  @behaviour Casein.AgentSessions.Provider

  alias Casein.AgentSessions.GrokACP
  alias Casein.AgentSessions.GrokACP.Attachments
  alias Casein.AgentSessions.Provider.{PendingRequest, SessionSpec}

  @provider_id :grok_acp
  @default_attachment_key "default"

  @impl true
  def capabilities, do: [:observe, :approve]

  @impl true
  def start_session(%SessionSpec{} = spec) do
    key = attachment_key(spec)

    with {:ok, _pid} <- GrokACP.ensure_started(spec.workspace_id, spec.cwd, spec.opts),
         :ok <- maybe_attach(spec, key) do
      {:ok,
       %{
         provider_id: @provider_id,
         workspace_id: spec.workspace_id,
         attachment_key: key
       }}
    end
  end

  @impl true
  def stop_session(%{workspace_id: workspace_id, attachment_key: key})
      when is_binary(workspace_id) do
    # Idempotent by contract: an observer that is already gone is a success.
    case GrokACP.whereis(workspace_id, key) do
      {:ok, pid} -> GrokACP.stop(pid)
      :error -> :ok
    end
  end

  def stop_session(_session_ref), do: {:error, :invalid_session_ref}

  @impl true
  def status(%{workspace_id: workspace_id, attachment_key: key} = ref)
      when is_binary(workspace_id) do
    case GrokACP.whereis(workspace_id, key) do
      {:ok, pid} ->
        {:ok,
         %{
           provider_id: @provider_id,
           session_ref: ref,
           # Named for the contract, not for Grok: an observer is "attached",
           # which is the closest honest analogue of Codex's :ready.
           status: :observing,
           raw: GrokACP.status(pid)
         }}

      :error ->
        {:error, {:not_observing, workspace_id, key}}
    end
  end

  def status(_session_ref), do: {:error, :invalid_session_ref}

  # send_turn/3 is intentionally NOT implemented — see the moduledoc. The
  # dispatcher gates it on the :drive capability, which this adapter does not
  # declare, so it never reaches here.

  @impl true
  def respond_to_request(
        %{workspace_id: workspace_id, attachment_key: key},
        request_id,
        decision
      )
      when is_binary(workspace_id) do
    case decision do
      {:choice, :cancel} ->
        Attachments.cancel_permission(workspace_id, key, request_id)

      {:choice, option_id} ->
        Attachments.respond_permission(workspace_id, key, request_id, to_string(option_id))

      {:decision, :cancel} ->
        Attachments.cancel_permission(workspace_id, key, request_id)

      # Grok's choices are opaque ids the agent supplied; there is no policy
      # vocabulary to map onto, so refuse rather than guess an option.
      {:decision, other} ->
        {:error, {:unsupported_decision_shape, other}}

      other ->
        {:error, {:invalid_decision, other}}
    end
  end

  def respond_to_request(_session_ref, _request_id, _decision), do: {:error, :invalid_session_ref}

  @impl true
  def pending_requests(%{workspace_id: workspace_id, attachment_key: key} = ref)
      when is_binary(workspace_id) do
    requests =
      workspace_id
      |> Attachments.list()
      |> Enum.filter(&matches_attachment?(&1, key))
      |> Enum.flat_map(&pending_from_snapshot(&1, ref))

    {:ok, requests}
  end

  def pending_requests(_session_ref), do: {:error, :invalid_session_ref}

  defp pending_from_snapshot(snapshot, ref) do
    snapshot
    |> value(:pending_permissions, [])
    |> Enum.map(fn request ->
      PendingRequest.new(%{
        provider_id: @provider_id,
        session_ref: ref,
        request_id: value(request, :request_id) || value(request, :id),
        title: value(request, :title) || "Grok needs permission to continue",
        detail: value(request, :detail) || value(request, :description),
        # A non-empty option list marks an option-list provider: the UI renders
        # the agent's own choices rather than accept/decline.
        options: value(request, :options),
        requested_at: value(request, :requested_at),
        metadata: value(request, :metadata, %{})
      })
    end)
  end

  defp matches_attachment?(snapshot, key) do
    case value(snapshot, :attachment_key) do
      nil -> true
      found -> to_string(found) == to_string(key)
    end
  end

  # Only attach when the caller named a session to resume. A fresh observer has
  # nothing to attach to yet, and a not-yet-running leader is not an error here —
  # ensure_started/3 has already been given its chance.
  defp maybe_attach(%SessionSpec{} = spec, key) do
    if SessionSpec.resume?(spec) do
      case GrokACP.whereis(spec.workspace_id, key) do
        {:ok, pid} -> normalize_attach(GrokACP.attach(pid, spec.session_id))
        :error -> :ok
      end
    else
      :ok
    end
  end

  defp normalize_attach(:ok), do: :ok
  defp normalize_attach({:ok, _snapshot}), do: :ok
  defp normalize_attach({:error, reason}), do: {:error, reason}
  defp normalize_attach(other), do: {:error, {:unexpected_attach_result, other}}

  defp attachment_key(%SessionSpec{opts: opts}),
    do: Keyword.get(opts, :attachment_key, @default_attachment_key)

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp value(_map, _key, default), do: default
end
