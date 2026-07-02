defmodule DevIDE.Panes.PaneBehaviourTest do
  use DevIDE.TestCase, async: false

  alias DevIDE.Panes.Pane, as: PaneBehaviour
  alias DevIDE.Panes.Terminal, as: TerminalPane
  alias DevIDE.Terminals.SessionTemplate.Pane
  alias DevIDE.Terminals.SessionTemplate.Window
  alias DevIDE.Terminals.Templates.Executor
  alias DevIDE.Terminals.Templates.ReconcileExecutor
  alias DevIDE.Terminals.Templates.Reconciler

  # Stub preview implementation: records attach calls so we can assert the pipeline
  # brings a :preview node to life without standing up the real PreviewPanes stack.
  defmodule StubPreview do
    @behaviour DevIDE.Panes.Pane

    @impl true
    def attach(node, ctx) do
      send(Application.get_env(:dev_ide, :stub_test_pid), {:stub_attach, ctx, node})

      case Application.get_env(:dev_ide, :stub_attach_result, :ok) do
        :ok -> {:ok, ctx.pane_id}
        {:error, _} = err -> err
      end
    end

    @impl true
    def serialize(_ref), do: %{"type" => "preview"}

    @impl true
    def terminate(_ref), do: :ok
  end

  describe "pane type dispatch" do
    test "impl/1 resolves built-in implementations" do
      assert PaneBehaviour.impl(:terminal) == DevIDE.Panes.Terminal
      assert PaneBehaviour.impl(:preview) == DevIDE.Panes.Preview
    end

    test "impl/1 honors :pane_impls override" do
      Application.put_env(:dev_ide, :pane_impls, %{preview: StubPreview})
      on_exit(fn -> Application.delete_env(:dev_ide, :pane_impls) end)

      assert PaneBehaviour.impl(:preview) == StubPreview
      # Non-overridden types still resolve to defaults.
      assert PaneBehaviour.impl(:terminal) == DevIDE.Panes.Terminal
    end

    test "types/0 lists known pane types" do
      assert Enum.sort(PaneBehaviour.types()) == [:preview, :terminal]
    end
  end

  describe "template struct :type" do
    test "Pane.new defaults to :terminal and parses :preview" do
      assert {:ok, %Pane{type: :terminal}} = Pane.new(%{})
      assert {:ok, %Pane{type: :preview}} = Pane.new(%{"type" => "preview"})
      assert {:ok, %Pane{type: :terminal}} = Pane.new(%{"type" => "bogus"})
      assert {:error, :invalid_pane_type} = Pane.new(%Pane{type: :nope})
    end

    test "Window.new defaults to :terminal and parses :preview" do
      assert {:ok, %Window{type: :terminal}} = Window.new(%{"name" => "w"})
      assert {:ok, %Window{type: :preview}} = Window.new(%{"name" => "w", "type" => "preview"})
    end
  end

  describe "executor planning (dry_run)" do
    test "terminal leaf emits send_command, preview leaf emits attach_pane" do
      {:ok, dry} = Executor.dry_run(saved_mixed_template())

      actions = Enum.map(dry.steps, & &1.action)
      assert "send_command" in actions
      assert "attach_pane" in actions

      attach = Enum.find(dry.steps, &(&1.action == "attach_pane"))
      assert attach.params.type == "preview"
      assert attach.params.command == "http://localhost:3000"

      # The preview payload is never sent to a shell.
      refute Enum.any?(dry.steps, fn step ->
               step.action == "send_command" and step.params[:command] == "http://localhost:3000"
             end)
    end
  end

  describe "reconciler diff" do
    test "preview node produces an attach_pane change and counts it" do
      {:ok, diff} =
        Reconciler.diff(empty_topology(), saved_mixed_template(), workspace_root: "/ws")

      attach = Enum.find(diff.changes, &(&1.action == "attach_pane"))
      assert attach
      assert attach.type == "preview"
      assert attach.command == "http://localhost:3000"
      assert diff.summary.attach_panes == 1
    end
  end

  describe "reconcile execution wiring" do
    setup do
      Application.put_env(:dev_ide, :stub_test_pid, self())
      Application.put_env(:dev_ide, :pane_impls, %{preview: StubPreview})

      on_exit(fn ->
        Application.delete_env(:dev_ide, :pane_impls)
        Application.delete_env(:dev_ide, :stub_test_pid)
        Application.delete_env(:dev_ide, :stub_attach_result)
      end)

      :ok
    end

    test "attach_pane change invokes the Pane behaviour with pane id and url" do
      {:ok, diff} =
        Reconciler.diff(empty_topology(), saved_preview_only_template(), workspace_root: "/ws")

      assert {:ok, result} =
               ReconcileExecutor.execute("api-session", diff,
                 tmux: DevIDE.Test.FakeTmuxAdapter,
                 workspace_root: "/ws",
                 workspace_id: "ws-1"
               )

      assert_receive {:stub_attach, ctx, node}
      assert is_binary(ctx.pane_id)
      assert ctx.workspace_id == "ws-1"
      assert ctx.tmux_session == "api-session"
      assert node.command == "http://localhost:3000"

      attach_exec = Enum.find(result.executed_changes, &(&1.action == "attach_pane"))
      assert attach_exec.result.attached == ctx.pane_id
    end

    test "attach failure degrades to a recorded error instead of crashing the reconcile" do
      Application.put_env(:dev_ide, :stub_attach_result, {:error, :boom})

      {:ok, diff} =
        Reconciler.diff(empty_topology(), saved_preview_only_template(), workspace_root: "/ws")

      assert {:ok, result} =
               ReconcileExecutor.execute("api-session", diff,
                 tmux: DevIDE.Test.FakeTmuxAdapter,
                 workspace_root: "/ws",
                 workspace_id: "ws-1"
               )

      attach_exec = Enum.find(result.executed_changes, &(&1.action == "attach_pane"))
      assert attach_exec.result.attach_error =~ "boom"
    end
  end

  describe "terminal adapter" do
    test "serialize tags terminal and carries command/cwd" do
      assert TerminalPane.serialize(%{command: "mix phx.server", cwd: "/ws"}) == %{
               "type" => "terminal",
               "command" => "mix phx.server",
               "cwd" => "/ws"
             }
    end

    test "attach is a no-op acknowledgment returning the pane id" do
      assert TerminalPane.attach(%{}, %{pane_id: "%1"}) == {:ok, "%1"}
      assert TerminalPane.attach(%{}, %{}) == {:ok, nil}
    end

    test "set_active is a no-op (terminal focus stays in the web layer)" do
      assert TerminalPane.set_active("%1", true) == :ok
    end
  end

  describe "export preview tagging" do
    alias DevIDE.Terminals.SessionTemplate.Export

    test "without a preview lookup, panes export as terminals (unchanged)" do
      {:ok, template} = Export.from_topology(single_pane_topology(), workspace_root: "/ws")
      leaf = hd(template["windows"])["layout"]
      refute Map.has_key?(leaf, "type")
    end

    test "matching panes are retagged :preview with the URL payload" do
      {:ok, template} =
        Export.from_topology(single_pane_topology(),
          workspace_root: "/ws",
          preview_panes: %{"%1" => "http://localhost:3000"}
        )

      leaf = hd(template["windows"])["layout"]
      assert leaf["type"] == "preview"
      assert leaf["command"] == "http://localhost:3000"
    end
  end

  # --- fixtures ----------------------------------------------------------------

  defp single_pane_topology do
    %{
      session: "devide_alpha_main",
      version: 1,
      windows: [
        %{
          id: "@1",
          index: 0,
          name: "main",
          active: true,
          pane_list: [
            %{
              id: "%1",
              window_id: "@1",
              index: 0,
              active: true,
              left: 0,
              top: 0,
              width: 80,
              height: 40,
              current_command: "node",
              current_path: "/ws"
            }
          ]
        }
      ],
      panes: []
    }
  end

  defp saved_mixed_template do
    base_template([
      %{"name" => "app", "cwd" => "${workspace_root}", "command" => "mix phx.server"},
      %{"name" => "preview", "type" => "preview", "command" => "http://localhost:3000"}
    ])
  end

  defp saved_preview_only_template do
    base_template(%{
      "name" => "preview",
      "type" => "preview",
      "command" => "http://localhost:3000"
    })
  end

  defp base_template(layout_panes) when is_list(layout_panes) do
    base_template(%{"direction" => "horizontal", "panes" => layout_panes})
  end

  defp base_template(layout) do
    %{
      id: "tpl-preview",
      name: "preview_layout",
      description: "v2 layout with a preview pane",
      source_session: "original",
      schema_version: 2,
      body: %{
        "version" => 2,
        "name" => "preview_layout",
        "root" => "${workspace_root}",
        "windows" => [
          %{"name" => "main", "root" => "${workspace_root}", "layout" => layout}
        ],
        "startup" => %{"window" => "main"}
      },
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }
  end

  defp empty_topology do
    %{session: "api-session", version: 1, windows: [], panes: []}
  end
end
