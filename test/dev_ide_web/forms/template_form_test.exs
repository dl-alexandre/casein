defmodule DevIdeWeb.Forms.TemplateFormTest do
  use DevIDE.TestCase, async: true

  alias DevIdeWeb.Forms.TemplateForm

  test "requires a non-blank name" do
    changeset =
      %{"name" => "   ", "description" => "x", "tags" => ""}
      |> TemplateForm.from_params()
      |> TemplateForm.validate()
      |> Map.put(:action, :validate)

    refute changeset.valid?
    assert {"can't be blank", _} = Keyword.fetch!(changeset.errors, :name)
  end

  test "accepts a valid template payload" do
    changeset =
      %{"name" => "Agent pair", "description" => "  two panes ", "tags" => "tmux"}
      |> TemplateForm.from_params()
      |> TemplateForm.validate()

    assert changeset.valid?

    assert %{name: "Agent pair", description: "two panes", tags: "tmux"} =
             TemplateForm.apply(changeset)
  end
end
