defmodule DevIDE.Mobile do
  @moduledoc """
  Boundary root for mobile companion projections.

  The mobile context owns user-facing card shaping and per-user observer
  processes. Web channels may consume this boundary through its exported card
  and observer modules; mobile-specific decisions stay out of the generic
  session channel transport.
  """

  use Boundary,
    deps: [DevIDE, DevIde.Repo],
    exports: [Card, UserObserver, Actions, ActionOutcome]
end
