defmodule Casein.Terminals.WorkerCancelTest do
  use ExUnit.Case, async: true

  alias Casein.Terminals.WorkerCancel

  @ws "ws-cancel-1"
  @session "casein_ws-cancel-1_main"

  defp worker_facts(overrides \\ %{}) do
    Map.merge(
      %{
        pane_id: "%42",
        window_id: "@9",
        window_name: "worker-demo",
        fleet_role: :worker,
        window_count: 3,
        caller_window_id: "@1"
      },
      overrides
    )
  end

  defp observe(facts) do
    fn _session, _pane, _window_id -> {:ok, facts} end
  end

  defp killer_ok do
    fn session, window_id ->
      send(self(), {:killed, session, window_id})
      :ok
    end
  end

  describe "cancel/1 validation" do
    test "fails closed without required fields" do
      assert {:error, %{error: :missing_argument, argument: "workspace_id"}} =
               WorkerCancel.cancel([])

      assert {:error, %{error: :missing_argument, argument: "session"}} =
               WorkerCancel.cancel(workspace_id: @ws)

      assert {:error, %{error: :missing_argument, argument: "pane"}} =
               WorkerCancel.cancel(workspace_id: @ws, session: @session)
    end

    test "pane not found is structured" do
      observe = fn _, _, _ -> {:error, %{error: :pane_not_found, pane: "%99"}} end

      assert {:error, %{error: :pane_not_found}} =
               WorkerCancel.cancel(
                 workspace_id: @ws,
                 session: @session,
                 pane: "%99",
                 observe: observe
               )
    end
  end

  describe "cancel/1 receipt" do
    test "live kill returns cancelled receipt and calls killer with window id" do
      assert {:ok, receipt} =
               WorkerCancel.cancel(
                 workspace_id: @ws,
                 session: @session,
                 pane: "%42",
                 observe: observe(worker_facts()),
                 killer: killer_ok(),
                 record_handle: false
               )

      assert receipt.ok == true
      assert receipt.cancelled? == true
      assert receipt.visible? == false
      assert receipt.pane_id == "%42"
      assert receipt.window_id == "@9"
      assert receipt.window_name == "worker-demo"
      assert receipt.note =~ "M4.1"
      assert_received {:killed, @session, "@9"}
    end

    test "kill failure is structured and never claims cancelled" do
      killer = fn _, _ -> {:error, %{error: :kill_failed, message: "tmux refused"}} end

      assert {:error, %{error: :kill_failed}} =
               WorkerCancel.cancel(
                 workspace_id: @ws,
                 session: @session,
                 pane: "%42",
                 observe: observe(worker_facts()),
                 killer: killer
               )
    end
  end

  describe "cancel/1 fail closed" do
    test "refuses a manager pane" do
      facts = worker_facts(%{fleet_role: :manager, window_name: "manager"})

      assert {:error, %{error: :not_a_worker, fleet_role: "manager"}} =
               WorkerCancel.cancel(
                 workspace_id: @ws,
                 session: @session,
                 pane: "%42",
                 observe: observe(facts),
                 killer: killer_ok()
               )

      refute_received {:killed, _, _}
    end

    test "refuses an unlabeled pane even when a window id is present" do
      facts = worker_facts(%{fleet_role: nil, window_name: "shell", label: nil})

      assert {:error, %{error: :not_a_worker}} =
               WorkerCancel.cancel(
                 workspace_id: @ws,
                 session: @session,
                 pane: "%42",
                 observe: observe(facts),
                 killer: killer_ok()
               )

      refute_received {:killed, _, _}
    end

    test "classifies worker-<slug> window names as workers" do
      facts = worker_facts(%{fleet_role: nil, window_name: "worker-384-item"})

      assert {:ok, %{cancelled?: true}} =
               WorkerCancel.cancel(
                 workspace_id: @ws,
                 session: @session,
                 pane: "%42",
                 observe: observe(facts),
                 killer: killer_ok(),
                 record_handle: false
               )
    end

    test "refuses the caller's own pane" do
      assert {:error, %{error: :same_window}} =
               WorkerCancel.cancel(
                 workspace_id: @ws,
                 session: @session,
                 pane: "%42",
                 caller_pane: "%42",
                 observe: observe(worker_facts()),
                 killer: killer_ok()
               )

      refute_received {:killed, _, _}
    end

    test "refuses the caller's own window" do
      facts = worker_facts(%{caller_window_id: "@9"})

      assert {:error, %{error: :same_window}} =
               WorkerCancel.cancel(
                 workspace_id: @ws,
                 session: @session,
                 pane: "%42",
                 caller_pane: "%7",
                 observe: observe(facts),
                 killer: killer_ok()
               )

      refute_received {:killed, _, _}
    end

    test "refuses the last window in the session" do
      facts = worker_facts(%{window_count: 1})

      assert {:error, %{error: :last_window, window_count: 1}} =
               WorkerCancel.cancel(
                 workspace_id: @ws,
                 session: @session,
                 pane: "%42",
                 observe: observe(facts),
                 killer: killer_ok()
               )

      refute_received {:killed, _, _}
    end

    test "refuses an unknown window count rather than guessing" do
      facts = worker_facts() |> Map.delete(:window_count)

      assert {:error, %{error: :unknown_window_count}} =
               WorkerCancel.cancel(
                 workspace_id: @ws,
                 session: @session,
                 pane: "%42",
                 observe: observe(facts),
                 killer: killer_ok()
               )

      refute_received {:killed, _, _}
    end

    test "refuses a numeric window index — tmux renumbers" do
      facts = worker_facts(%{window_id: "3"})

      assert {:error, %{error: :invalid_window_id, window_id: "3"}} =
               WorkerCancel.cancel(
                 workspace_id: @ws,
                 session: @session,
                 pane: "%42",
                 observe: observe(facts),
                 killer: killer_ok()
               )

      refute_received {:killed, _, _}
    end

    test "refuses a missing window id" do
      facts = worker_facts() |> Map.delete(:window_id)

      assert {:error, %{error: :missing_window_id}} =
               WorkerCancel.cancel(
                 workspace_id: @ws,
                 session: @session,
                 pane: "%42",
                 observe: observe(facts),
                 killer: killer_ok()
               )

      refute_received {:killed, _, _}
    end
  end

  # Constraints in the artifact (not only the brief). If a later slice "helpfully"
  # adds WindowTrash hide-as-cancel, dry_run cancelled?, or durable graph fields,
  # these fail first — briefs die with the pane (#384 / fleet signal-honesty).
  describe "contract: no silent product-principle undo" do
    test "dry_run never claims the worker is gone" do
      killer = fn _, _ ->
        send(self(), :killed)
        :ok
      end

      assert {:ok, plan} =
               WorkerCancel.cancel(
                 workspace_id: @ws,
                 session: @session,
                 pane: "%42",
                 dry_run: true,
                 observe: observe(worker_facts()),
                 killer: killer
               )

      assert plan.dry_run == true
      assert plan.cancelled? == false
      assert plan.visible? == true
      assert plan.window_id == "@9"
      refute_received :killed
    end

    test "cancelled? is true only after the killer returns :ok" do
      killer = fn _, _ -> {:error, %{error: :kill_failed}} end

      assert {:error, %{error: :kill_failed}} =
               WorkerCancel.cancel(
                 workspace_id: @ws,
                 session: @session,
                 pane: "%42",
                 observe: observe(worker_facts()),
                 killer: killer
               )
    end

    test "receipt does not invent durable-graph / verifier fields (out of scope)" do
      assert {:ok, receipt} =
               WorkerCancel.cancel(
                 workspace_id: @ws,
                 session: @session,
                 pane: "%42",
                 observe: observe(worker_facts()),
                 killer: killer_ok(),
                 record_handle: false
               )

      # do not grow M4.1 into orchestration_create by stealth — durable graph
      # / path contracts / verifiers stay on later #384 milestones.
      forbid = [
        :orchestration_id,
        :task_id,
        :attempt_id,
        :contract_version,
        :path_contract,
        :verifier_run_id,
        :evidence_packet
      ]

      for key <- forbid do
        refute Map.has_key?(receipt, key),
               "receipt must not carry #{key} (out of scope for worker_cancel M4.1)"
      end
    end

    test "killer is invoked with @N window id, never a bare index" do
      killer = fn _session, window_id ->
        assert window_id =~ ~r/\A@\d+\z/
        refute window_id =~ ~r/\A\d+\z/
        send(self(), {:killed, window_id})
        :ok
      end

      assert {:ok, _} =
               WorkerCancel.cancel(
                 workspace_id: @ws,
                 session: @session,
                 pane: "%42",
                 observe: observe(worker_facts()),
                 killer: killer,
                 record_handle: false
               )

      assert_received {:killed, "@9"}
    end
  end
end
