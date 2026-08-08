defmodule Casein.Attention do
  @moduledoc """
  Shared attention model: **signal**, **salience**, and **delivery**.

  One place computes *what happened* and *how much it matters*. Surfaces choose
  thresholds over that salience; they do not invent their own definition of
  "important."

  ## Layers

  - `Casein.Attention.Signal` — domain events (`:agent_blocked`, `:idle`, …),
    not UI states.
  - `Casein.Attention.Salience` — how much a signal matters, computed **once**
    for all surfaces (generalized from `Casein.Mobile.AttentionInbox` ranking).
  - `Casein.Attention.Delivery` — per-surface threshold over salience, plus
    focus-aware routing (`surface_state` / `target_state`).

  ## Projections (kept, not deleted)

  - `Casein.Mobile.AttentionInbox` — mobile envelope (lifecycle, cursors) over
    shared salience.
  - `Casein.Terminals.SessionDirectory.Attention` — session-picker
    `%{section, reason}` over shared salience (`:idle` = agent went quiet, you
    are needed; see #696).
  - `Casein.Attention.Policy` — `delivery_*` reaction enum over
    `Casein.Attention.Delivery` (suppress / inline / notify).

  Vocabulary for the dual former `:quiet` meanings follows #696: session reason
  `:idle`, policy helpers `delivery_*`. The directory window flag `:quiet` and
  telemetry `[:casein, :attention, :quiet_agent, :transition]` still name the
  quiet-agent *fact*.
  """
end
