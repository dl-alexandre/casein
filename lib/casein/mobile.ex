defmodule Casein.Mobile do
  @moduledoc """
  Public facade for mobile companion projections.

  The mobile context owns user-facing card shaping and per-user observer
  processes. Web channels may consume this boundary through its exported card
  and observer modules; mobile-specific decisions stay out of the generic
  session channel transport.

  This facade remains part of the main `Casein` domain boundary. Keeping it
  there permits domain event dispatchers and the web transport to share the
  same exported context without introducing a circular top-level boundary.
  """
end
