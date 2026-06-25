defmodule DevIdeWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias DevIdeWeb.CoreComponents

  describe "button/1" do
    test "renders a default soft primary button with its slot" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.button phx-click="go">Click me</CoreComponents.button>
        """)

      assert html =~ "<button"
      assert html =~ "btn-primary btn-soft"
      assert html =~ "Click me"
    end

    test "renders a primary variant" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.button variant="primary">Save</CoreComponents.button>
        """)

      assert html =~ "btn-primary"
      assert html =~ "Save"
    end

    test "renders a link when given navigate" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.button navigate="/home">Home</CoreComponents.button>
        """)

      assert html =~ "<a"
      assert html =~ "Home"
    end
  end

  describe "icon/1 and split_icon/1" do
    test "icon renders a hero span" do
      assigns = %{}
      html = rendered_to_string(~H|<CoreComponents.icon name="hero-x-mark" />|)
      assert html =~ "hero-x-mark"
    end

    test "split_icon renders right and down variants" do
      assigns = %{}
      right = rendered_to_string(~H|<CoreComponents.split_icon direction={:right} />|)
      down = rendered_to_string(~H|<CoreComponents.split_icon direction={:down} />|)

      assert right =~ "<svg"
      assert right =~ ~s(x1="12")
      assert down =~ ~s(y1="12")
    end
  end

  describe "flash/1" do
    test "renders an info flash with inner content" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.flash kind={:info}>All good</CoreComponents.flash>
        """)

      assert html =~ "alert-info"
      assert html =~ "All good"
    end

    test "renders an error flash with a title" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.flash kind={:error} title="Oops">Bad thing</CoreComponents.flash>
        """)

      assert html =~ "alert-error"
      assert html =~ "Oops"
      assert html =~ "Bad thing"
    end
  end

  describe "header/1, list/1, table/1" do
    test "header renders title, subtitle, and actions slots" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.header>
          Title here
          <:subtitle>Some subtitle</:subtitle>
          <:actions>Do it</:actions>
        </CoreComponents.header>
        """)

      assert html =~ "Title here"
      assert html =~ "Some subtitle"
      assert html =~ "Do it"
    end

    test "list renders item titles and content" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.list>
          <:item title="Name">Alice</:item>
          <:item title="Role">Admin</:item>
        </CoreComponents.list>
        """)

      assert html =~ "Name"
      assert html =~ "Alice"
      assert html =~ "Role"
      assert html =~ "Admin"
    end

    test "table renders rows through column slots" do
      assigns = %{rows: [%{name: "row-a"}, %{name: "row-b"}]}

      html =
        rendered_to_string(~H"""
        <CoreComponents.table id="t" rows={@rows}>
          <:col :let={r} label="Name">{r.name}</:col>
        </CoreComponents.table>
        """)

      assert html =~ "Name"
      assert html =~ "row-a"
      assert html =~ "row-b"
    end
  end

  describe "input/1" do
    setup do
      %{form: to_form(%{"email" => "a@b.com", "agree" => "true"}, as: :user)}
    end

    test "renders a text input from a form field", %{form: form} do
      assigns = %{form: form}

      html =
        rendered_to_string(~H"""
        <CoreComponents.input field={@form[:email]} type="text" label="Email" />
        """)

      assert html =~ ~s(name="user[email]")
      assert html =~ "a@b.com"
      assert html =~ "Email"
    end

    test "renders a checkbox input" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.input name="agree" type="checkbox" label="Agree" value={true} />
        """)

      assert html =~ ~s(type="checkbox")
      assert html =~ "Agree"
    end

    test "renders a select input with options" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.input
          name="role"
          type="select"
          label="Role"
          prompt="Pick one"
          value="admin"
          options={[{"Admin", "admin"}, {"User", "user"}]}
        />
        """)

      assert html =~ "<select"
      assert html =~ "Admin"
      assert html =~ "Pick one"
    end

    test "renders a textarea input" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.input name="bio" type="textarea" label="Bio" value="hello" />
        """)

      assert html =~ "<textarea"
      assert html =~ "hello"
    end

    test "renders a hidden input" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.input name="token" type="hidden" value="abc123" />
        """)

      assert html =~ ~s(type="hidden")
      assert html =~ "abc123"
    end

    test "renders explicit error messages" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.input name="email" type="text" value="x@y.com" errors={["is invalid"]} />
        """)

      assert html =~ "is invalid"
    end
  end

  describe "error translation and JS helpers" do
    test "translate_error returns a string" do
      assert CoreComponents.translate_error({"is invalid", []}) == "is invalid"
    end

    test "translate_error interpolates count" do
      assert CoreComponents.translate_error({"should have %{count} items", [count: 3]}) =~ "3"
    end

    test "translate_errors filters by field" do
      errors = [email: {"is invalid", []}, name: {"too short", []}]
      assert CoreComponents.translate_errors(errors, :email) == ["is invalid"]
    end

    test "show/1 and hide/1 return JS structs" do
      assert %Phoenix.LiveView.JS{} = CoreComponents.show("#modal")
      assert %Phoenix.LiveView.JS{} = CoreComponents.hide("#modal")
    end
  end
end
