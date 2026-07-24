defmodule Casein.RateLimit do
  @moduledoc """
  Application-wide Hammer rate limiter (ETS backend).
  """

  use Hammer, backend: :ets
end
