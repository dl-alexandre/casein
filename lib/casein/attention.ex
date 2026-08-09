defmodule Casein.Attention do
  @moduledoc """
  Shared attention model: **signal**, **salience**, and **delivery**.

  One place computes *what happened* and *how much it matters*. Surfaces choose
  thresholds over that salience; they do not invent their own definition of
  "important."

  ## Layers

  - `Casein.Attention.Signal` — domain events (`:agent_blocked`,
    `:agent_errored`, `:agent_stalled`, `:idle`, …), not UI states.
  - `Casein.Attention.Salience` — how much a signal matters, computed **once**
    for all surfaces (generalized from `Casein.Mobile.AttentionInbox` ranking).
  - `Casein.Attention.Delivery` — per-surface threshold over salience, plus
    focus-aware routing (`surface_state` / `target_state`).

  ## Projections (kept, not deleted)

  - `Casein.Mobile.AttentionInbox` — mobile envelope (lifecycle) over shared
    salience; SEEN writes go through `Casein.Attention.Acknowledgement`.
  - `Casein.Terminals.SessionDirectory.Attention` — session-picker
    `%{section, reason}` over shared salience (`:idle` = agent went quiet, you
    are needed; see #696). Reasons `:errored` / `:stalled` stay distinct from
    `:blocked` (report-only vs derived-only; see `AgentState`).
  - `Casein.Attention.Policy` — `delivery_*` reaction enum over
    `Casein.Attention.Delivery` (suppress / inline / notify).

  ## Acknowledgement (#698)

  - `Casein.Attention.Acknowledgement` — **SEEN** and **RESOLVED** as one
    cross-surface, per-viewer fact (phone, drawer, session rail). Not a second
    definition of importance; Delivery may consume `seen?` / `resolved?`.

  ## Push ≠ cockpit (H28)

  `Delivery.push_eligible?/1` is a stricter threshold than
  `Delivery.session_needs_you?/1`. Same salience definition; different cuts.
  Stalled agents and quiet-window idle are cockpit-visible without paging the
  phone by default.

  ## Unknown must never mean calm

  Externally-observed liveness (`AgentLiveness` / `PaneLiveness`) keeps
  `{:error, _}` structurally distinct from "quiet." Salience never fabricates
  an idle/quiet fact from an unscannable worktree. Callers that collapse
  unknown into quiet will tell operators everything is fine when observation
  has simply gone blind.

  Vocabulary for the dual former `:quiet` meanings follows #696: session reason
  `:idle`, policy helpers `delivery_*`. The directory window flag `:quiet` and
  telemetry `[:casein, :attention, :quiet_agent, :transition]` still name the
  quiet-agent *fact*.
  """
end
