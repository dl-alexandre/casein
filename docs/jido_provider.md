# Jido OpenCode Zen provider

Provider slice for [#1012](https://github.com/dl-alexandre/casein/issues/1012),
stacked after the #1014-#1018 implementation and the #1039 contract hardening.
It gives Casein a real Jido.AI/ReqLLM provider boundary for Grok 4.6 without
creating a second OpenCode Zen credential.

## Fixed provider route

`Casein.Agents.JidoProvider` delegates to
`Casein.Agents.JidoProvider.OpenCodeZen` by default. The adapter fixes all
credential-bearing routing fields at the trusted boundary:

| Field | Value |
|-------|-------|
| Casein provider | `opencode` |
| Casein model | `opencode/grok-4.6` |
| Zen API model | `grok-4.6` |
| Base URL | `https://opencode.ai/zen/v1` |
| ReqLLM wire protocol | `openai_responses` (`POST /responses`) |

Callers may pass bounded generation options such as `max_tokens`, `timeout`,
and Jido tool definitions. Caller-supplied `api_key`, `model`, `base_url`, and
unknown options are discarded. This prevents a task or model-authored value
from redirecting the existing credential to another host.

OpenCode's current Zen catalog documents Grok 4.6 on the Responses endpoint:
[OpenCode Zen](https://opencode.ai/docs/zen/). Jido.AI's generation facade and
direct model-spec contract are documented in
[Jido.AI 2.3](https://jido-ai.hexdocs.pm/Jido.AI.html) and the
[ReqLLM model-spec guide](https://github.com/agentjido/req_llm/blob/main/guides/model-specs.md).

## Runtime credential reuse

`OpenCodeAuth.fetch_api_key/0` resolves the credential for every request:

1. Read `OPENCODE_AUTH_CONTENT` when present. A valid document is authoritative;
   it must contain an `opencode` record with `type: "api"` and a non-empty `key`.
2. If the environment value is absent or is not JSON, read
   `${XDG_DATA_HOME}/opencode/auth.json`.
3. When `XDG_DATA_HOME` is absent, use
   `${HOME}/.local/share/opencode/auth.json`.

This matches OpenCode's source and CLI storage contract:
[auth loader](https://github.com/anomalyco/opencode/blob/dev/packages/opencode/src/auth/index.ts),
[OpenCode CLI authentication](https://opencode.ai/docs/cli/).

The key is never copied into `CASEIN_*`, `/etc/casein/casein.env`, Casein
configuration, Jido.AI configuration, ReqLLM configuration, lifecycle events,
attempt state, or logs. It exists only as a per-request option passed from the
resolver to Jido.AI. The resolver does not cache, so OpenCode key rotation takes
effect on the next call without restarting Casein. ReqLLM dotenv discovery is
disabled to keep this one credential authority.

## Public contract

```elixir
Casein.Agents.JidoProvider.info()
Casein.Agents.JidoProvider.configured?()
Casein.Agents.JidoProvider.generate(prompt, max_tokens: 4096, timeout: 60_000)
```

Successful calls return Jido.AI's normalized response. Failures are reduced to
a secret-free shape:

```elixir
{:error,
 %{
   error: :provider_unavailable,
   reason: :credential_not_found,
   retryable: false,
   provider: "opencode",
   model: "opencode/grok-4.6"
 }}
```

Upstream error bodies, request structs, headers, and credential-source contents
do not cross the adapter boundary. A provider request failure uses
`reason: :request_failed` and `retryable: true`; local configuration failures
are not retryable.

## Current integration boundary

This slice supplies the provider adapter and production Jido.AI dependency. It
does not alter the existing #1014 pod's deterministic typed-action execution.
Manager MCP (`jido_admit` / `jido_status` / `jido_cancel`) admits that typed
list; it does not invoke this provider as a reasoning loop. Wiring the
provider into a model-selected tool loop and adding durable attempt/action-run
checkpoints, leases, and idempotency remain explicit follow-ups. Persistence is
scheduled only after this provider PR lands cleanly.

Focused coverage lives in `test/casein/agents/jido_provider_test.exs` and proves
auth precedence, fresh reads after rotation, fixed Responses routing,
non-overridable credentials/endpoint, and secret-free errors without making a
live provider request.
