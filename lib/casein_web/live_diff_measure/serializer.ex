defmodule CaseinWeb.LiveDiffMeasure.Serializer do
  @moduledoc """
  Thin `Phoenix.Socket.Serializer` wrapper that measures LiveView diff wire
  bytes (#899). Delegates encode/decode to `Phoenix.Socket.V2.JSONSerializer`;
  measurement is best-effort and never raises into the transport.

  # do not change encode shape or drop V1 negotiation (#899 measure-only —
  # wire bytes must stay byte-identical to stock V2 so this cannot be blamed
  # for a cockpit regression; optimisations land in a follow-up issue).
  """

  @behaviour Phoenix.Socket.Serializer

  alias CaseinWeb.LiveDiffMeasure
  alias Phoenix.Socket.V2.JSONSerializer

  @impl true
  defdelegate decode!(raw_message, opts), to: JSONSerializer

  @impl true
  def encode!(msg) do
    # Measure after stock encode — never rewrite the iodata.
    result = JSONSerializer.encode!(msg)
    maybe_measure(msg, result)
    result
  end

  @impl true
  def fastlane!(msg) do
    result = JSONSerializer.fastlane!(msg)
    maybe_measure(msg, result)
    result
  end

  defp maybe_measure(msg, encoded) do
    if LiveDiffMeasure.enabled?() do
      case LiveDiffMeasure.classify_message(msg) do
        {:measure, kind, event, _payload} ->
          LiveDiffMeasure.emit_wire(kind, event, LiveDiffMeasure.iodata_bytes(encoded))

        :skip ->
          :ok
      end
    end
  rescue
    _ -> :ok
  end
end
