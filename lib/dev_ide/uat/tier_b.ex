defmodule DevIDE.UAT.TierB do
  @moduledoc """
  Tier B — the post-deploy acceptance smoke. Drives the **live release node** over
  its real MCP surface (`POST /api/preview/mcp` on `/run/devide/current.sock`) as
  the workspace owner's forward-auth identity, runs a small set of read-mostly
  criteria agent-driven, and persists each as a `tier_b` `DevIDE.UAT.Run`.

  Unlike Tier A this is not deterministic replay; the agent drives live. The wire
  is behind `DevIDE.UAT.TierB.Transport` (default `SocketTransport`) so envelope,
  identity, and failure-policy logic are testable without a running node.

  ## Failure policy (`alert_for/1`)

    * `:pass`    → `:ok`
    * `:fail`    → `:regression_alert` (advisory; v1 does NOT auto-rollback)
    * `:drift`   → `:needs_triage` (do not auto-propose against a live run —
      Tier A is the authoritative re-author surface)
    * `:errored` → `:infra_alert` (couldn't run; never silently green)

  ## Trust invariant

  Posting to the release socket sets `X-Auth-Request-Email` directly, bypassing
  the Caddy proxy that normally sets/strips it — so reaching
  `/run/devide/current.sock` is equivalent to being any user. The socket's
  filesystem permissions are the only auth boundary, and the app MUST ignore
  this header on any path not behind the trusted proxy. `:endpoint` must stay
  config-only — never derived from agent/verdict data.
  """

  alias DevIDE.UAT.{Run, TierB.SocketTransport, Verdict}

  @default_socket "/run/devide/current.sock"
  @forward_auth_header "X-Auth-Request-Email"

  @doc "Build a JSON-RPC 2.0 request envelope for an MCP method."
  @spec envelope(String.t(), map(), term()) :: map()
  def envelope(method, params, id \\ 1) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
  end

  @doc "Forward-auth identity headers for `identity` (the workspace owner email)."
  @spec identity_headers(String.t() | nil) :: %{optional(String.t()) => String.t()}
  def identity_headers(identity) when is_binary(identity) and identity != "",
    do: %{@forward_auth_header => identity}

  def identity_headers(_), do: %{}

  @doc """
  Perform one MCP `method` call against the live node.

  Options: `:transport` (default `SocketTransport`), `:endpoint` (default the
  release socket), `:identity` (forward-auth email), `:headers` (extra), `:id`.
  """
  @spec rpc(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def rpc(method, params, opts \\ []) do
    transport = Keyword.get(opts, :transport, SocketTransport)
    endpoint = Keyword.get(opts, :endpoint, default_socket())

    headers =
      opts
      |> Keyword.get(:identity)
      |> identity_headers()
      |> Map.merge(Keyword.get(opts, :headers, %{}))

    transport.rpc(endpoint, envelope(method, params, Keyword.get(opts, :id, 1)), headers)
  end

  @doc "Map a run outcome to the Tier B alert policy."
  @spec alert_for(atom()) :: {atom(), atom()}
  def alert_for(:pass), do: {:pass, :ok}
  def alert_for(:fail), do: {:fail, :regression_alert}
  def alert_for(:drift), do: {:drift, :needs_triage}
  def alert_for(_), do: {:errored, :infra_alert}

  @doc """
  Run one criterion against the live node and persist a `tier_b` `Run`.

  The `:agent` (which drives the MCP tools via `rpc/3`) is injected so the
  orchestration + policy are testable. Returns `{outcome, alert, run}` where
  `outcome` is `:pass`/`:fail`/`:errored` and `alert` is from `alert_for/1`.
  """
  @spec run_criterion(String.t(), integer(), map(), keyword()) ::
          {atom(), atom(), Run.t()} | {:error, term()}
  def run_criterion(criterion, session_id, attrs, opts) do
    repo = Keyword.get(opts, :repo, DevIde.Repo)
    {outcome, verdict} = evaluate(criterion, session_id, opts)
    {_, alert} = alert_for(outcome)

    case persist(repo, attrs, session_id, outcome, verdict, opts) do
      {:ok, run} -> {outcome, alert, run}
      {:error, _} = err -> err
    end
  end

  defp evaluate(criterion, session_id, opts) do
    # Only the injected agent (an arbitrary fn driving the live node) is allowed
    # to blow up the smoke into :errored — a bug in Verdict.validate must surface,
    # so it runs OUTSIDE the rescue.
    case run_agent(criterion, session_id, opts) do
      {:ok, verdict} ->
        case Verdict.validate(verdict, session_id, opts) do
          {:ok, %{"passed" => true} = v} -> {:pass, v}
          {:ok, v} -> {:fail, v}
          {:error, errors} -> {:errored, %{"errors" => errors}}
        end

      {:errored, _} = errored ->
        errored
    end
  end

  defp run_agent(criterion, session_id, opts) do
    agent = Keyword.fetch!(opts, :agent)
    {:ok, agent.(criterion, session_id)}
  rescue
    e -> {:errored, %{"exception" => Exception.message(e)}}
  end

  defp persist(repo, attrs, session_id, outcome, verdict, opts) do
    %Run{}
    |> Run.changeset(%{
      scenario_id: Map.get(attrs, :scenario_id, "tier_b"),
      tier: :tier_b,
      target_instance: Keyword.get(opts, :endpoint, default_socket()),
      session_id: session_id,
      outcome: outcome,
      verdict: verdict
    })
    |> repo.insert()
  end

  defp default_socket do
    Application.get_env(:dev_ide, :uat_tier_b_socket, @default_socket)
  end
end
