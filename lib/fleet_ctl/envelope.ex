defmodule FleetCtl.Envelope do
  @moduledoc """
  Pure validation helpers for versioned protocol envelopes.
  """

  @spec valid_uuid?(term()) :: boolean()
  def valid_uuid?(nil), do: false

  def valid_uuid?(value) when is_binary(value) do
    String.length(value) == 36 and
      Regex.match?(~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i, value)
  end

  def valid_uuid?(_), do: false

  @spec valid_datetime?(term()) :: boolean()
  def valid_datetime?(%DateTime{}), do: true
  def valid_datetime?(_), do: false
end
