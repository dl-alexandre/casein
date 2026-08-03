defmodule Casein.Test.FailingMobileClarification do
  @moduledoc false

  def resolve(_card, _attrs), do: {:error, :forced_resolution_failure}
end
