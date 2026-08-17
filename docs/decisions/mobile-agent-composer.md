# Mobile agent composer: compose-first only on agent panes

Status: phase-1 prototype, behind a default-off flag

Parent: [issue #977](https://github.com/dl-alexandre/casein/issues/977)

## Decision

On a handset, a role-tagged agent pane gets a native textarea composer beneath
the rendered terminal transcript. An ordinary shell pane remains grid-first and
keeps the existing terminal key bar. There is no global Async/Live mode toggle:
Casein already knows which pane hosts an agent, so the input surface follows the
pane rather than a viewer preference.

Send uses `Casein.Terminals.PaneSubmit`, including its confirmed-landing and
single Enter retry behavior. Send later uses the one existing
`Casein.Terminals.NextPrompt` slot and its unchanged latest-wins coalescing.

Enable the prototype with `CASEIN_MOBILE_AGENT_COMPOSER=1`. It is off by
default. Phase 1 deliberately adds no draft persistence or cross-device sync.

## Persistence safety invariant

If persistence is added later, an unsent draft must never hydrate into another
tmux conversation. The existing NextPrompt slot is keyed by
`{tmux_session, pane_id}`; tmux pane ids are stable for the pane's life, and no
code under `lib/` keys this behavior by mutable window index. Draft persistence
must retain the same conversation identity property.
