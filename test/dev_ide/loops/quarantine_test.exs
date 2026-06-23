defmodule DevIDE.Loops.QuarantineTest do
  use DevIde.DataCase, async: false

  alias DevIDE.Audit
  alias DevIDE.Loops.Quarantine
  alias DevIDE.Policy

  setup do
    prev = Application.get_env(:dev_ide, DevIDE.Loops)
    Audit.clear()

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:dev_ide, DevIDE.Loops)
        val -> Application.put_env(:dev_ide, DevIDE.Loops, val)
      end

      Audit.clear()
    end)

    :ok
  end

  test "enabled? is false by default" do
    Application.delete_env(:dev_ide, DevIDE.Loops)
    refute Quarantine.enabled?()
  end

  test "authorize! denies and audits when loops disabled" do
    Application.put_env(:dev_ide, DevIDE.Loops, enabled: false)

    assert {:error, :not_allowed} = Quarantine.authorize!(%{actor_type: :system})

    assert [%{action: "policy.blocked", decision: :deny, reason: :not_allowed}] =
             Audit.list() |> Enum.map(&Map.take(&1, [:action, :decision, :reason]))
  end

  test "authorize! records loop_run_id and workspace_id in audit metadata" do
    Application.put_env(:dev_ide, DevIDE.Loops, enabled: true)

    assert :ok =
             Quarantine.authorize!(%{
               actor_type: :system,
               loop_run_id: "run-abc",
               workspace_id: "ws-xyz"
             })

    assert [%{metadata: %{loop_run_id: "run-abc"}, workspace_id: "ws-xyz"}] =
             Audit.list()
             |> Enum.filter(&(&1.action == "loops.authorize"))
             |> Enum.map(fn e -> %{metadata: e.metadata, workspace_id: e.workspace_id} end)
  end

  test "authorize! allows when loops enabled" do
    Application.put_env(:dev_ide, DevIDE.Loops, enabled: true)
    assert :ok = Quarantine.authorize!(%{actor_type: :system})
  end

  test "Policy.can_run_loop? mirrors enabled flag" do
    Application.put_env(:dev_ide, DevIDE.Loops, enabled: false)
    assert %Policy.Decision{verdict: :deny} = Policy.can_run_loop?(%{})

    Application.put_env(:dev_ide, DevIDE.Loops, enabled: true)
    assert %Policy.Decision{verdict: :allow} = Policy.can_run_loop?(%{})
  end
end
