defmodule Casein.AgentSessions do
  @moduledoc """
  Entry point for structured agent runtimes.

  Resolves a `provider_id` to an adapter and gates the optional callbacks on the
  capabilities that adapter declares. The gate lives **here**, not in each
  adapter, so an unsupported call returns `{:error, {:unsupported, :send_turn}}`
  from the seam rather than crashing inside a runtime that was never asked to do
  it.

  That matters because Casein's two runtimes are asymmetric on purpose:
  `Casein.Codex.AppServer` drives turns, while `Casein.AgentSessions.GrokACP` is
  an observer that must never send them. See
  `Casein.AgentSessions.Provider` for why capability is data.

  ## Configuration

  Adapters resolve through `config :casein, :agent_session_providers` with the
  default set in `config/config.exs` and read via `Application.fetch_env!/2`.
  Note the deliberate absence of a module-literal `Application.get_env/3`
  default: a module literal in a `get_env/3` default is itself a compile-time
  edge, and that is how xref cycles were re-entangled in #347/#348. The config
  file owns the default; this module only reads it.
  """

  alias Casein.AgentSessions.Provider
  alias Casein.AgentSessions.Provider.SessionSpec

  @type provider_id :: atom()

  @doc "Known provider ids, in a stable order for UI listing."
  @spec provider_ids() :: [provider_id()]
  def provider_ids, do: providers() |> Map.keys() |> Enum.sort()

  @doc "Adapter module for `provider_id`."
  @spec adapter(provider_id()) :: {:ok, module()} | {:error, {:unknown_provider, provider_id()}}
  def adapter(provider_id) when is_atom(provider_id) do
    case Map.fetch(providers(), provider_id) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, {:unknown_provider, provider_id}}
    end
  end

  @doc "Capabilities declared by `provider_id`."
  @spec capabilities(provider_id()) :: {:ok, [Provider.capability()]} | {:error, term()}
  def capabilities(provider_id) do
    with {:ok, module} <- adapter(provider_id), do: {:ok, module.capabilities()}
  end

  @doc """
  True when `provider_id` declares `capability`.

  UI should ask this rather than hardcoding a provider list — that is what keeps
  a declared-but-unimplemented capability like `:interrupt` from needing special
  cases at every call site.
  """
  @spec capable?(provider_id(), Provider.capability()) :: boolean()
  def capable?(provider_id, capability) do
    case capabilities(provider_id) do
      {:ok, declared} -> capability in declared
      {:error, _reason} -> false
    end
  end

  @doc "Start or attach a session."
  @spec start_session(provider_id(), SessionSpec.t() | keyword() | map()) ::
          {:ok, Provider.session_ref()} | {:error, term()}
  def start_session(provider_id, %SessionSpec{} = spec) do
    with {:ok, module} <- adapter(provider_id), do: module.start_session(spec)
  end

  def start_session(provider_id, attrs),
    do: start_session(provider_id, SessionSpec.new(attrs))

  @doc "Tear down a session. Idempotent."
  @spec stop_session(provider_id(), Provider.session_ref()) :: :ok | {:error, term()}
  def stop_session(provider_id, session_ref) do
    with {:ok, module} <- adapter(provider_id), do: module.stop_session(session_ref)
  end

  @doc "Session snapshot."
  @spec status(provider_id(), Provider.session_ref()) :: {:ok, map()} | {:error, term()}
  def status(provider_id, session_ref) do
    with {:ok, module} <- adapter(provider_id), do: module.status(session_ref)
  end

  @doc """
  Submit a turn. Requires `:drive`.

  An observer-only provider returns `{:error, {:unsupported, :send_turn}}` — a
  contract outcome, not a crash.
  """
  @spec send_turn(provider_id(), Provider.session_ref(), term(), keyword()) ::
          {:ok, Provider.turn_ref()} | {:error, term()}
  def send_turn(provider_id, session_ref, input, opts \\ []) do
    gated(provider_id, {:send_turn, 3}, fn module ->
      module.send_turn(session_ref, input, opts)
    end)
  end

  @doc "Cancel an in-flight turn. Requires `:interrupt` (no adapter implements this yet)."
  @spec interrupt_turn(provider_id(), Provider.session_ref(), Provider.turn_ref()) ::
          :ok | {:error, term()}
  def interrupt_turn(provider_id, session_ref, turn_ref) do
    gated(provider_id, {:interrupt_turn, 2}, fn module ->
      module.interrupt_turn(session_ref, turn_ref)
    end)
  end

  @doc "Resolve a pending approval. Requires `:approve`."
  @spec respond_to_request(
          provider_id(),
          Provider.session_ref(),
          Provider.request_id(),
          Provider.decision()
        ) :: {:ok, map()} | {:error, term()}
  def respond_to_request(provider_id, session_ref, request_id, decision) do
    gated(provider_id, {:respond_to_request, 3}, fn module ->
      module.respond_to_request(session_ref, request_id, decision)
    end)
  end

  @doc "Pending requests for a session. Requires `:approve`."
  @spec pending_requests(provider_id(), Provider.session_ref()) ::
          {:ok, [Provider.PendingRequest.t()]} | {:error, term()}
  def pending_requests(provider_id, session_ref) do
    gated(provider_id, {:pending_requests, 1}, fn module ->
      module.pending_requests(session_ref)
    end)
  end

  defp gated(provider_id, {name, _arity} = callback, fun) do
    with {:ok, module} <- adapter(provider_id),
         :ok <- ensure_capable(module, callback, name) do
      fun.(module)
    end
  end

  defp ensure_capable(module, callback, name) do
    required = Map.fetch!(Provider.gated_callbacks(), callback)

    if required in module.capabilities() do
      :ok
    else
      {:error, {:unsupported, name}}
    end
  end

  defp providers, do: Application.fetch_env!(:casein, :agent_session_providers)
end
