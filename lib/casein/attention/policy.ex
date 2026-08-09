defmodule Casein.Attention.Policy do
  @moduledoc """
  Pure attention-routing rules for operator-facing agent state.

  **Projection** over `Casein.Attention.Delivery` — not an independent
  definition of importance. Callers gather facts from their own layer (browser
  focus, LiveView session, tmux topology) and pass only low-cardinality values
  here. The policy returns a small reaction enum so UI surfaces can stay
  consistent: stay quiet, render inline chrome, or ask the browser for an OS
  notification.

  ## `delivery_*` means how (or whether) to surface a signal

  `delivery_reason`, `delivery_decision/1`, `delivery_reaction/1`, and
  `window_delivery/1` answer *suppress / inline / notify* for an already-known
  operator-facing transition. A `delivery_reason` of `:focused_target` means
  "do not page the operator" — not "the agent is idle".

  It deliberately does **not** mean "an agent has gone quiet, therefore you are
  needed". That session-picker signal is `Casein.Terminals.SessionDirectory.Attention`
  reason `:idle` (raised from the directory window's `:quiet` flag). Do not
  reuse `:idle` or name delivery helpers `quiet_*`.

  Ranking and signal identity live in `Casein.Attention.Salience` /
  `Casein.Attention.Signal`. This module only applies delivery thresholds and
  focus-aware routing.
  """

  alias Casein.Attention.Delivery

  @type surface_state :: Delivery.surface_state()
  @type target_state :: Delivery.target_state()
  @type reaction :: Delivery.reaction()
  @type delivery_reason :: Delivery.delivery_reason()
  @type delivery_decision :: Delivery.delivery_decision()

  @doc "Normalize browser/workspace surface state from atoms or client strings."
  @spec surface_state(term()) :: surface_state()
  defdelegate surface_state(state), to: Delivery

  @doc "Normalize the target's relationship to the current operator surface."
  @spec target_state(term()) :: target_state()
  defdelegate target_state(state), to: Delivery

  @doc """
  Attention reaction for a quiet-agent transition.

  `observed_working?` must be true before an OS notification is considered. A
  cold ready window still gets inline chrome, but it should not page the
  operator just because they loaded or reconnected to the workspace.
  """
  @spec delivery_reaction(map()) :: reaction()
  defdelegate delivery_reaction(attrs), to: Delivery

  @doc """
  Full delivery decision with normalized inputs and a reason for telemetry.

  Names the suppress/inline/notify choice for a quiet-agent transition — not
  the session-picker `:idle` reason.
  """
  @spec delivery_decision(map()) :: delivery_decision()
  defdelegate delivery_decision(attrs), to: Delivery

  @doc "Attention reaction for steady quiet-agent chrome."
  @spec window_delivery(map()) :: reaction()
  defdelegate window_delivery(attrs), to: Delivery

  @doc "JSON-safe reaction label for browser payloads and data attributes."
  @spec reaction_label(reaction()) :: String.t()
  defdelegate reaction_label(reaction), to: Delivery
end
