defmodule Casein.Agents.AnnotationToolsActionTest do
  @moduledoc """
  Unit tests for the Jido.Action-backed annotation tool surface.
  """
  use ExUnit.Case, async: true

  alias Casein.Agents.AnnotationTools

  describe "definitions/0" do
    test "exposes list and propose with annotation metadata" do
      defs = AnnotationTools.definitions()
      assert length(defs) == 2

      list = Enum.find(defs, &(&1.name == "annotation_list"))
      propose = Enum.find(defs, &(&1.name == "annotation_propose"))

      assert list.metadata.mutation? == false
      assert list.metadata.capabilities == [:terminal_read]
      assert propose.metadata.mutation? == true
      assert propose.metadata.policy_tags == [:human_review]
    end

    test "wire schema keeps workspace_id required on both tools" do
      for tool <- AnnotationTools.definitions() do
        assert "workspace_id" in tool.parameters.required
      end
    end
  end

  describe "invoke/2 validation" do
    test "preserves missing_workspace_id from Impl" do
      assert {:error, :missing_workspace_id} = AnnotationTools.invoke("annotation_list", %{})
    end

    test "unknown tools return :unknown_tool" do
      assert {:error, :unknown_tool} = AnnotationTools.invoke("annotation_delete", %{})
    end
  end
end
