defmodule Casein.AgentSessions.Provider do
  @moduledoc """
  One contract over Casein's structured agent runtimes.

  Casein already drives two of them, independently and with no shared seam:

  | | Codex | Grok |
  |---|---|---|
  | wire | JSON-RPC over stdio (`Casein.Codex.AppServer`) | ACP over stdio (`Casein.AgentSessions.GrokACP`) |
  | session start | `start_thread/3`, `resume_thread/4` | `ensure_started/3` + `attach/2` |
  | send a turn | `start_turn/5` | **none — observer only** |
  | approvals | `Codex.ApprovalBroker` (6 decision kinds) | `respond_permission/3`, `cancel_permission/2` |

  Two working stacks is good; two *unrelated* stacks means every cross-provider
  question (what needs my approval? which sessions are live?) gets answered
  twice, and a third runtime costs a third rewrite. This module is the seam.

  ## Driver vs observer is the whole design

  `GrokACP` is deliberately an **observer**: it loads the same ACP session as the
  human's TUI to become a leader subscriber, so tool/plan/permission events can
  be projected without scraping terminal output. It must never send turns — the
  human drives.

  `Codex.AppServer` is a **driver**: it owns the thread and submits turns.

  A flat five-callback behaviour would force `send_turn/3` onto the observer,
  and every adapter would grow an `{:error, :not_supported}` branch. So
  capability is declared data, checked at the dispatcher, and the optional
  callbacks simply do not exist on adapters that cannot honour them.

  ## Callbacks

  Required of every adapter:

    * `c:capabilities/0` — which optional callbacks this adapter honours
    * `c:start_session/1`, `c:stop_session/1`, `c:status/1`

  Optional, each gated on a declared capability:

    * `c:send_turn/3` — requires `:drive`
    * `c:interrupt_turn/2` — requires `:interrupt`
    * `c:respond_to_request/3` — requires `:approve`

  ## `:interrupt` ships with zero implementations, on purpose

  Neither runtime can interrupt a turn today. In Codex, `grep -rn "interrupt"
  lib/casein/codex/` finds only `protocol.ex` mapping an *inbound* `"interrupted"`
  status, and `ApprovalBroker`'s `:cancel` is approval-scoped, not turn-scoped.
  The callback is declared so the UI can hide the affordance by asking
  `capable?/2` rather than by hardcoding a provider list. Declaring it and
  implementing nothing is honest; faking it is not.
  """

  alias Casein.AgentSessions.Provider.{PendingRequest, SessionSpec}

  @type capability :: :drive | :observe | :approve | :interrupt

  @typedoc """
  Opaque, adapter-owned session handle.

  Codex identifies a session by `runtime_id` + `thread_id`; Grok by
  `workspace_id` + `attachment_key`. Those do not unify, and forcing them into a
  shared shape would leak one runtime's model into the other. Callers must treat
  this as opaque and hand it back untouched.
  """
  @type session_ref :: term()

  @type turn_ref :: term()
  @type request_id :: term()

  @typedoc """
  A decision on a pending request.

  Deliberately a tagged union rather than one enum. Codex offers six decision
  kinds including `{:accept_with_execpolicy_amendment, [String.t()]}` and
  `{:apply_network_policy_amendment, map()}`; Grok offers an opaque `option_id`
  chosen from options the agent supplied. Flattening both to
  `:accept | :decline` for UI convenience would throw away Codex's amendments.
  """
  @type decision ::
          {:choice, request_option_id :: String.t()}
          | {:decision, atom() | tuple()}

  @doc "Capabilities this adapter honours. Must match its exported callbacks."
  @callback capabilities() :: [capability()]

  @doc "Start or attach a session. Returns an opaque, adapter-owned reference."
  @callback start_session(SessionSpec.t()) :: {:ok, session_ref()} | {:error, term()}

  @doc "Tear down a session. Must be idempotent."
  @callback stop_session(session_ref()) :: :ok | {:error, term()}

  @doc "Current session snapshot, including any pending requests."
  @callback status(session_ref()) :: {:ok, map()} | {:error, term()}

  @doc "Submit user input as a turn. Requires the `:drive` capability."
  @callback send_turn(session_ref(), input :: term(), opts :: keyword()) ::
              {:ok, turn_ref()} | {:error, term()}

  @doc "Cancel an in-flight turn. Requires the `:interrupt` capability."
  @callback interrupt_turn(session_ref(), turn_ref()) :: :ok | {:error, term()}

  @doc "Resolve a pending approval/permission. Requires the `:approve` capability."
  @callback respond_to_request(session_ref(), request_id(), decision()) ::
              {:ok, map()} | {:error, term()}

  @doc "Pending requests for a session, normalized across providers."
  @callback pending_requests(session_ref()) :: {:ok, [PendingRequest.t()]} | {:error, term()}

  @optional_callbacks send_turn: 3,
                      interrupt_turn: 2,
                      respond_to_request: 3,
                      pending_requests: 1

  @doc """
  Optional callbacks and the capability each one requires.

  The dispatcher and the conformance harness both read this, so a new gated
  callback is declared in exactly one place.
  """
  @spec gated_callbacks() :: %{{atom(), arity()} => capability()}
  def gated_callbacks do
    %{
      {:send_turn, 3} => :drive,
      {:interrupt_turn, 2} => :interrupt,
      {:respond_to_request, 3} => :approve,
      {:pending_requests, 1} => :approve
    }
  end

  @doc "All capabilities an adapter may declare."
  @spec capabilities() :: [capability()]
  def capabilities, do: [:drive, :observe, :approve, :interrupt]

  @doc "True when `module` declares `capability`."
  @spec capable?(module(), capability()) :: boolean()
  def capable?(module, capability) when is_atom(module) and is_atom(capability) do
    capability in module.capabilities()
  rescue
    UndefinedFunctionError -> false
  end
end
