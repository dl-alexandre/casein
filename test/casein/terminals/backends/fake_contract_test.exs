defmodule Casein.Terminals.Backends.FakeContractTest do
  @moduledoc """
  Expanded Fake Backend contract coverage for behaviour shapes product
  conversions depend on (session_exists?/2, send_command, direction norms,
  agent_pair plan apply, dead-session errors).

  Linux-honest only — does **not** prove ConPTY or Job Object execution.
  Disjoint from product call-site conversion slices: touches Fake + this test
  (and freeze-line docs), not SessionOwner/TmuxOps/MCP impl modules.
  """

  use ExUnit.Case, async: false

  alias Casein.Terminals.Backend
  alias Casein.Terminals.Backends.Fake
  alias Casein.Terminals.SessionTemplate

  @session "fake_slice4_session"

  setup do
    Fake.reset!()
    assert :ok = Fake.ensure_session(@session, File.cwd!())
    :ok
  end

  describe "adapter-parity helpers" do
    test "session_exists?/2 accepts cwd: without changing existence" do
      assert Fake.session_exists?(@session)
      assert Fake.session_exists?(@session, cwd: "/tmp")
      assert Fake.session_exists?(@session, [])
      refute Fake.session_exists?("missing", cwd: "/tmp")
    end

    test "mark_dead! flips alive while keeping the session registered" do
      assert Fake.session_exists?(@session)
      assert Fake.session_alive?(@session)
      assert :ok = Fake.mark_dead!(@session)
      assert Fake.session_exists?(@session)
      refute Fake.session_alive?(@session)
      assert {:error, :session_not_alive} = Fake.send_keys(@session, "x")
      assert {:error, :session_not_alive} = Fake.window_size(@session)
      assert {:error, :session_not_found} = Fake.mark_dead!("ghost")
    end

    test "list_sessions/0 enumerates registered sessions as adapter maps" do
      sessions = Fake.list_sessions()
      assert Enum.any?(sessions, &(&1.session == @session))
      assert :ok = Fake.ensure_session("other_fake", File.cwd!())
      ids = Fake.session_ids() |> Enum.sort()
      assert "other_fake" in ids
      assert @session in ids
    end

    test "send_command/3 appends newline and targets pane" do
      assert :ok = Fake.send_command(@session, "echo hi")
      assert {:ok, text} = Fake.capture_recent(@session, 5)
      assert text =~ "echo hi\n"

      assert {:ok, agent} = Fake.split_pane(@session, "%1", "h", role: "agent")
      assert :ok = Fake.send_command(@session, "git status", target: agent)
      assert Fake.capture_scrollback(@session, target: agent) =~ "git status\n"
      refute Fake.capture_scrollback(@session, target: "%1") =~ "git status"
    end

    test "paste_text/3 and inject/3 write scrollback; directory_inventory is complete" do
      assert :ok = Fake.paste_text(@session, "brief body", submit: false)
      assert Fake.capture_scrollback(@session) =~ "brief body"
      refute Fake.capture_scrollback(@session) =~ "brief body\n"

      assert :ok = Fake.paste_text(@session, "line", submit: true)
      assert Fake.capture_scrollback(@session) =~ "line\n"

      assert :ok = Fake.inject(@session, "injected", enter: false)
      assert Fake.capture_scrollback(@session) =~ "injected"

      assert {:ok, %{windows: windows, panes: panes}} = Fake.directory_inventory()
      assert Map.has_key?(windows, @session)
      assert Map.has_key?(panes, @session)
      assert is_list(windows[@session])
      assert is_list(panes[@session])

      assert is_list(Fake.list_windows())
      assert is_list(Fake.list_panes())
      assert Fake.resize_amount_default() > 0
      assert Fake.resize_amount_max() >= Fake.resize_amount_default()
      assert Fake.server_version() == {0, 0}
      assert Fake.tail_lines("a\nb\nc", 2) == "b\nc"
    end
  end

  describe "split and resize direction norms" do
    test "accepts template h/v and long names; rejects junk" do
      assert {:ok, a} = Fake.split_pane(@session, "%1", "h")
      assert {:ok, b} = Fake.split_pane(@session, "%1", "vertical")
      assert {:ok, c} = Fake.split_pane(@session, "%1", "horizontal")

      assert Fake.get_pane(@session, a).split_direction == "h"
      assert Fake.get_pane(@session, b).split_direction == "v"
      assert Fake.get_pane(@session, c).split_direction == "h"

      assert {:error, :invalid_direction} = Fake.split_pane(@session, "%1", "diagonal")
      assert {:error, :invalid_pane} = Fake.split_pane(@session, "%999", "h")
    end

    test "resize_pane rejects invalid direction and clamps shrink" do
      assert {:ok, pane} = Fake.split_pane(@session, "%1", "h")
      before = Fake.get_pane(@session, pane)
      assert :ok = Fake.resize_pane(@session, pane, "L", 10_000)
      after_w = Fake.get_pane(@session, pane).width
      assert after_w == 1
      assert after_w < before.width

      assert {:error, :invalid_direction} = Fake.resize_pane(@session, pane, "Z", 1)
      assert {:error, :invalid_pane} = Fake.resize_pane(@session, "%999", "R", 1)
    end
  end

  describe "error taxonomy for missing/dead targets" do
    test "ops on missing session return session_not_found" do
      assert {:error, :session_not_found} = Fake.attach("nope")
      assert {:error, :session_not_found} = Fake.resize_window("nope", 80, 24)
      assert {:error, :session_not_found} = Fake.new_window("nope", [])
      assert {:error, :session_not_found} = Fake.select_pane("nope", "%1")
      assert {:error, :session_not_found} = Fake.kill_pane("nope", "%1")
      assert {:error, :session_not_found} = Fake.set_pane_role("nope", "%1", "agent")
    end

    test "invalid role and invalid window/pane" do
      assert {:error, :invalid_pane_role} = Fake.set_pane_role(@session, "%1", "wizard")
      assert {:error, :invalid_window} = Fake.select_window(@session, "@99")
      assert {:error, :invalid_window} = Fake.kill_window(@session, "@99")
      assert {:error, :invalid_pane} = Fake.select_pane(@session, "%99")
      assert :ok = Fake.set_pane_role(@session, "%1", nil)
      assert Fake.get_pane(@session, "%1").role == nil
    end

    test "ensure_session is idempotent and re-alives a dead session" do
      assert :ok = Fake.mark_dead!(@session)
      refute Fake.session_alive?(@session)
      assert :ok = Fake.ensure_session(@session, "/tmp/rebind")
      assert Fake.session_alive?(@session)
      assert Fake.get(@session).cwd == "/tmp/rebind"
    end
  end

  describe "agent_pair plan apply (Fake-only)" do
    test "SessionTemplate.dry_run agent_pair applies through Fake.apply_plan/2" do
      assert {:ok, %{steps: steps, step_count: n}} = SessionTemplate.dry_run("agent_pair")
      assert n > 0
      assert Enum.any?(steps, &(&1.action == "new_window"))
      assert Enum.any?(steps, &(&1.action == "split_pane"))
      assert Enum.any?(steps, &(&1.action == "send_command"))

      assert {:ok, refs} = Fake.apply_plan(@session, steps)
      assert is_map(refs)
      assert Map.has_key?(refs, "window:work")
      assert Map.has_key?(refs, "pane:work:root")
      assert Map.has_key?(refs, "pane:work:agent")
      assert Map.has_key?(refs, "pane:work:verify")

      {_windows, panes} = Fake.session_topology(@session)
      # original root + work window root + agent + verify
      assert length(panes) >= 4

      agent = Fake.get_pane(@session, refs["pane:work:agent"])
      verify = Fake.get_pane(@session, refs["pane:work:verify"])
      root = Fake.get_pane(@session, refs["pane:work:root"])

      assert agent.role == "agent"
      assert verify.role == "verify"
      assert root.role == "operator"

      assert Fake.capture_scrollback(@session, target: agent.id) =~ "Casein agent pane"
      assert Fake.capture_scrollback(@session, target: verify.id) =~ "git status"
    end

    test "apply_plan rejects unknown actions and missing sessions" do
      assert {:error, :session_not_found} =
               Fake.apply_plan("ghost", [%{action: "new_window", ref: "w", params: %{}}])

      assert {:error, {:unsupported_plan_action, "teleport"}} =
               Fake.apply_plan(@session, [%{action: "teleport", params: %{}}])
    end
  end

  describe "Backend.module selection stays independent of product modules" do
    test "Fake remains selectable as :terminal_backend" do
      previous = Application.get_env(:casein, :terminal_backend)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:casein, :terminal_backend, previous),
          else: Application.delete_env(:casein, :terminal_backend)
      end)

      Application.put_env(:casein, :terminal_backend, Fake)
      assert Backend.module() == Fake
      name = Backend.module().session_name("contract-ws", "sid")
      assert String.starts_with?(name, "fake_")
      assert :ok = Backend.module().ensure_session(name, File.cwd!())
      assert Backend.module().session_exists?(name)
    end
  end
end
