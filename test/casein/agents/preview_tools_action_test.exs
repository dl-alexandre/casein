defmodule Casein.Agents.PreviewToolsActionTest do
  @moduledoc """
  Unit tests for the Jido.Action-backed preview tool surface.
  """
  use ExUnit.Case, async: true

  alias Casein.Agents.PreviewTools

  describe "definitions/0" do
    test "exposes 28 preview tools" do
      assert length(PreviewTools.definitions()) == 28
    end

    test "preview_open pins mode on the wire" do
      tool = definition("preview_open")

      assert tool.parameters.properties.mode.enum == ["app", "localhost", "here"]
      assert tool.parameters.required == ["workspace_id"]
      assert tool.metadata.mutation? == true
    end

    test "preview_clear_storage keeps high-danger storage metadata" do
      tool = definition("preview_clear_storage")

      assert tool.metadata.danger_level == :high
      assert tool.metadata.policy_tags == [:storage_mutation]
    end
  end

  describe "invoke/3" do
    test "injects workspace_id from the workspace map before validation" do
      workspace = %{id: "ws-preview-action", path: "/tmp/ws"}

      assert {:error, :invalid_port} =
               PreviewTools.invoke("preview_open_localhost", workspace, %{})
    end

    test "unknown tools return :unknown_tool" do
      assert {:error, :unknown_tool} =
               PreviewTools.invoke("preview_not_real", %{id: "ws"}, %{})
    end
  end

  defp definition(name) do
    Enum.find(PreviewTools.definitions(), &(&1.name == name))
  end
end
