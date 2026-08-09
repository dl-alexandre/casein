defmodule Casein.Terminals.SessionDirectory.Attention do
  @moduledoc """
  Provider-neutral attention classification for session picker rows.

  **Projection** over `Casein.Attention.Salience` / `Casein.Attention.Delivery`
  — not an independent ranker. The classifier consumes the semantic metadata
  already attached by `Casein.Terminals.SessionDirectory`: reported agent state
  and the stable, quantized quiet flag. It deliberately does not infer an agent
  provider or inspect host processes. tmux remains the session transport, not
  agent identity.

  `group/1` is a stable partition. Callers can retain their existing recency or
  name ordering before grouping into `:needs_you`, `:working`, and `:recent`.

  ## `:idle` means you are needed

  Reason `:idle` is the session-picker signal for *an agent window has gone
  quiet, therefore the operator is needed* (`%{section: :needs_you, reason: :idle}`).
  It is raised from the directory window's quantized `:quiet` flag (see
  `Casein.Terminals.Activity`) and is ranked inside `:needs_you` after
  blocked/errored/stalled/completed.

  It deliberately does **not** mean "suppress this notification". Delivery
  routing — whether to stay silent, render inline chrome, or request an OS
  notification — lives in `Casein.Attention.Policy` under the `delivery_*`
  vocabulary. Do not reuse `:idle` or "quiet" there.

  ## `:errored` and `:stalled` stay distinct from `:blocked` (H28)

  - `:blocked` — agent reported it needs a human (report-only)
  - `:errored` — agent reported failure (report-only)
  - `:stalled` — derived from liveness; looks busy, worktree quiet

  These project from `Casein.Attention.Delivery.session_classification/1`.
  UI chrome must not re-derive the kind by re-inspecting window agent_state.
  """

  alias Casein.Attention.Delivery
  alias Casein.Terminals.Session.Info, as: SessionInfo

  @type section :: Delivery.session_section()
  @type reason :: Delivery.session_reason()
  @type classification :: Delivery.session_classification()
  @type groups :: %{
          needs_you: [SessionInfo.t()],
          working: [SessionInfo.t()],
          recent: [SessionInfo.t()]
        }

  @doc "Classifies one session using provider-neutral directory metadata."
  @spec classify(SessionInfo.t() | map()) :: classification()
  def classify(session) when is_map(session) do
    Delivery.classify_session(session)
  end

  @doc "Stable-partitions sessions into the three picker sections."
  @spec group([SessionInfo.t() | map()]) :: groups()
  def group(sessions) when is_list(sessions) do
    grouped = Enum.group_by(sessions, &classify(&1).section)

    %{
      needs_you: Map.get(grouped, :needs_you, []),
      working: Map.get(grouped, :working, []),
      recent: Map.get(grouped, :recent, [])
    }
  end
end
