defmodule McpCtl.ErrorTest do
  use Casein.TestCase, async: true

  alias McpCtl.Error

  test "format/1 normalizes atom errors" do
    assert %{"error" => "session_not_found"} = Error.format(:session_not_found)
  end

  test "tool_result/1 returns MCP error envelope" do
    result = Error.tool_result(:origin_not_allowed)

    assert result.isError
    assert result.structuredContent["error"] == "origin_not_allowed"
  end

  # A rejected changeset carries its schema struct in `:data`. Sanitizing that
  # struct as a plain map raised Protocol.UndefinedError, so an ordinary
  # validation failure surfaced to the MCP caller as an HTTP 500 with no
  # indication of which field was rejected.
  test "format/1 reports changeset validation errors instead of raising on the schema struct" do
    changeset =
      %Casein.Previews.Preview{}
      |> Casein.Previews.Preview.changeset(%{
        url: "https://untrusted.example.com/",
        workspace_id: "ws-1"
      })

    refute changeset.valid?

    assert %{
             "error" => "validation_failed",
             "details" => %{"url" => ["must be an http or https URL"]},
             "message" => "validation failed: url must be an http or https URL"
           } = Error.format(changeset)
  end

  test "tool_result/1 turns a changeset into an error envelope rather than crashing" do
    changeset =
      %Casein.Previews.Preview{}
      |> Casein.Previews.Preview.changeset(%{url: "not-a-url", workspace_id: "ws-1"})

    result = Error.tool_result(changeset)

    assert result.isError
    assert result.structuredContent["error"] == "validation_failed"
    assert result.content |> hd() |> Map.get(:text) =~ "validation failed"
  end

  test "format/1 interpolates the bindings Ecto leaves in a message" do
    changeset =
      {%{}, %{name: :string}}
      |> Ecto.Changeset.cast(%{name: "ab"}, [:name])
      |> Ecto.Changeset.validate_length(:name, min: 5)

    assert %{"details" => %{"name" => [message]}} = Error.format(changeset)
    assert message =~ "5"
    refute message =~ "%{count}"
  end

  test "format/1 keeps a struct nested in a reason from blowing up the formatter" do
    reason = {:preview_stale, %Casein.Previews.Preview{id: 7, url: "http://localhost:4000"}}

    assert %{"error" => "preview_stale", "details" => details} = Error.format(reason)
    assert is_binary(details)
    assert details =~ "Casein.Previews.Preview"
  end
end
