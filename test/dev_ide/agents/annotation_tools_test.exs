defmodule DevIDE.Agents.AnnotationToolsTest do
  use DevIDE.DataCase, async: false

  alias DevIDE.Agents.AnnotationTools
  alias DevIDE.Annotations
  alias DevIDE.Audit

  setup do
    Audit.clear()
    :ok
  end

  test "annotation_list returns workspace annotations with filters" do
    {:ok, pending} =
      Annotations.propose_from_agent("ws-tools", %{
        content: "Check selector",
        author_type: :agent_grok,
        file_path: "lib/app.ex"
      })

    {:ok, _approved} =
      Annotations.create("ws-tools", %{
        content: "Human note",
        author_type: :human,
        file_path: "README.md"
      })

    assert {:ok, %{annotations: annotations, count: 2}} =
             AnnotationTools.invoke("annotation_list", %{"workspace_id" => "ws-tools"})

    assert Enum.any?(annotations, &(&1.id == pending.id))

    assert {:ok, %{annotations: [only_pending], count: 1}} =
             AnnotationTools.invoke("annotation_list", %{
               "workspace_id" => "ws-tools",
               "approval_state" => "pending"
             })

    assert only_pending.id == pending.id
    assert only_pending.approval_state == "pending"
  end

  test "annotation_propose creates a pending annotation for review" do
    assert {:ok, %{annotation: annotation}} =
             AnnotationTools.invoke("annotation_propose", %{
               "workspace_id" => "ws-tools",
               "content" => "Stale test selector on save button",
               "author_type" => "agent_codex",
               "file_path" => "test/app_test.exs",
               "metadata" => %{"origin" => "mcp"}
             })

    assert annotation.approval_state == "pending"
    assert annotation.author_type == "agent_codex"
    assert annotation.file_path == "test/app_test.exs"

    assert [%{action: "annotation.created"} | _] = Audit.recent_for("ws-tools", 5)
  end

  test "annotation_propose requires context anchors" do
    assert {:error, {:invalid_annotation, errors}} =
             AnnotationTools.invoke("annotation_propose", %{
               "workspace_id" => "ws-tools",
               "content" => "No anchor",
               "author_type" => "agent_grok"
             })

    assert errors[:base]
  end
end
