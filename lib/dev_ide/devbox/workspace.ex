defmodule DevIDE.Devbox.Workspace do
  @moduledoc """
  Normalized view of a milc-devbox workspace.

  Shape mirrors what the Node manager returns from `GET /api/workspaces` and
  `GET /api/workspaces/:id/status`. The original payload is preserved under
  `:raw` for debugging and for fields we have not promoted to first-class.
  """

  @type status ::
          :creating | :queued | :starting | :running | :stopped | :deleting | :error | :unknown

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          user: String.t() | nil,
          branch: String.t() | nil,
          type: :v3 | :legacy | :unknown,
          status: status(),
          path: String.t() | nil,
          slot: integer() | nil,
          domain_base: String.t() | nil,
          ports: map(),
          created_at: String.t() | nil,
          last_started: String.t() | nil,
          raw: map()
        }

  defstruct [
    :id,
    :name,
    :user,
    :branch,
    :type,
    :status,
    :path,
    :slot,
    :domain_base,
    :ports,
    :created_at,
    :last_started,
    raw: %{}
  ]

  def from_payload(%{"workspace" => ws} = envelope) when is_map(ws) do
    from_payload(Map.put(ws, "_envelope", Map.delete(envelope, "workspace")))
  end

  def from_payload(map) when is_map(map) do
    %__MODULE__{
      id: map["id"],
      name: map["name"],
      user: map["user"],
      branch: map["branch"],
      type: parse_type(map["type"]),
      status: parse_status(map["status"]),
      path: map["path"],
      slot: map["slot"],
      domain_base: map["domainBase"],
      ports: map["ports"] || %{},
      created_at: map["createdAt"],
      last_started: map["lastStarted"],
      raw: map
    }
  end

  defp parse_type("v3"), do: :v3
  defp parse_type("legacy"), do: :legacy
  defp parse_type(_), do: :unknown

  defp parse_status("creating"), do: :creating
  defp parse_status("queued"), do: :queued
  defp parse_status("starting"), do: :starting
  defp parse_status("running"), do: :running
  defp parse_status("stopped"), do: :stopped
  defp parse_status("deleting"), do: :deleting
  defp parse_status("error"), do: :error
  defp parse_status(_), do: :unknown
end
