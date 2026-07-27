defmodule Casein.Workspaces.ReconcilerTest do
  @moduledoc """
  End-to-end behaviour of the sweep: what it refuses to act on, and what it
  writes when it does act.

  `async: false` — the sweep reads `:workspace_source` and its own config out of
  the application environment, and asserts on the shared `MemoryAdapter`.
  """
  use Casein.TestCase, async: false

  alias Casein.Integrations.Manager.Client
  alias Casein.Workspaces.Reconciler
  alias Casein.Workspaces.State
  alias Casein.Workspaces.State.MemoryAdapter
  alias Casein.Workspaces.State.WorkspaceRecord

  setup do
    MemoryAdapter.clear()
    Casein.Audit.MemoryAdapter.clear()
    :ok
  end

  # Long enough ago to clear the grace window in every test below. host_path
  # defaults to a guaranteed-absent directory so the real `File.dir?/1` disk
  # guard reads "deleted"; on-disk tests pass an existing dir explicitly.
  defp seed(external_id, opts) do
    {:ok, _} =
      MemoryAdapter.upsert(%WorkspaceRecord{
        external_id: external_id,
        name: external_id,
        user: Keyword.get(opts, :user, "dalexandre"),
        status: Keyword.get(opts, :status, "running"),
        host_path: Keyword.get(opts, :host_path, "/nonexistent/casein-test/#{external_id}"),
        last_seen_at: Keyword.get(opts, :last_seen_at, DateTime.add(DateTime.utc_now(), -1, :day))
      })
  end

  # Pushes a record's `last_seen_at` back past the grace window without
  # disturbing the rest of it. Needed after any `State` write, because every
  # one of them refreshes `last_seen_at`.
  defp age_record(external_id) do
    {:ok, record} = MemoryAdapter.get(external_id)

    {:ok, _} =
      MemoryAdapter.upsert(%{record | last_seen_at: DateTime.add(DateTime.utc_now(), -1, :day)})
  end

  defp status_of(external_id) do
    {:ok, record} = MemoryAdapter.get(external_id)
    record.status
  end

  # Stubs the two endpoints a sweep touches. `workspaces` is the listing;
  # `identity` is what GET /api/auth/me reports.
  defp stub_manager(workspaces, identity) do
    test = self()

    Req.Test.stub(Client, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      payload =
        case conn.path_info do
          ["api", "auth", "me"] ->
            identity

          ["api", "workspaces"] ->
            send(test, {:listed, conn.query_params})
            workspaces
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))
    end)
  end

  defp admin,
    do: %{"email" => "dalexandre@milcgroup.com", "user" => "dalexandre", "isAdmin" => true}

  defp non_admin, do: %{"email" => "jgiles@milcgroup.com", "user" => "jgiles", "isAdmin" => false}

  defp workspace(id, user), do: %{"id" => id, "name" => id, "user" => user, "status" => "running"}

  describe "source gate" do
    test "refuses to run under the Local source" do
      Application.put_env(:casein, :workspace_source, Casein.WorkspaceSource.Local)

      on_exit(fn ->
        Application.put_env(:casein, :workspace_source, Casein.WorkspaceSource.Manager)
      end)

      seed("deleted", [])
      stub_manager([workspace("alive", "dalexandre")], admin())

      assert %{status: :skipped, reason: {:source_not_manager, Casein.WorkspaceSource.Local}} =
               Reconciler.sweep(dry_run: false)

      # A directory-walk source is not authoritative about absence, so nothing moved.
      assert status_of("deleted") == "running"
      refute_received {:listed, _}
    end
  end

  describe "refusing bad evidence" do
    test "an empty listing never retires anything" do
      seed("deleted", [])
      stub_manager([], admin())

      assert %{status: :skipped, reason: :empty_listing} = Reconciler.sweep(dry_run: false)
      assert status_of("deleted") == "running"
    end

    test "a failed identity probe aborts before the listing is even fetched" do
      seed("deleted", [])

      Req.Test.stub(Client, fn conn ->
        Plug.Conn.resp(conn, 500, "boom")
      end)

      assert %{status: :skipped, reason: {:identity_probe_failed, _}} =
               Reconciler.sweep(dry_run: false)

      assert status_of("deleted") == "running"
    end

    test "a failed listing retires nothing" do
      seed("deleted", [])

      Req.Test.stub(Client, fn conn ->
        case conn.path_info do
          ["api", "auth", "me"] ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(200, Jason.encode!(admin()))

          ["api", "workspaces"] ->
            Plug.Conn.resp(conn, 503, "unavailable")
        end
      end)

      assert %{status: :skipped, reason: {:listing_failed, _}} = Reconciler.sweep(dry_run: false)
      assert status_of("deleted") == "running"
    end
  end

  describe "multi-tenancy" do
    test "a non-admin sweep leaves other users' records untouched" do
      seed("jgiles-deleted", user: "jgiles")
      seed("dalexandre-ws", user: "dalexandre")
      # The manager filtered this listing to jgiles; it says nothing about dalexandre.
      stub_manager([workspace("jgiles-alive", "jgiles")], non_admin())

      assert %{status: :ok, retired: ["jgiles-deleted"], scope: {:user, "jgiles"}} =
               Reconciler.sweep(dry_run: false)

      assert status_of("jgiles-deleted") == WorkspaceRecord.stale_status()
      assert status_of("dalexandre-ws") == "running"
    end

    test "an admin sweep asks for every user's workspaces" do
      seed("jgiles-deleted", user: "jgiles")
      stub_manager([workspace("dalexandre-alive", "dalexandre")], admin())

      assert %{status: :ok, retired: ["jgiles-deleted"], scope: :global} =
               Reconciler.sweep(dry_run: false)

      assert_received {:listed, %{"all" => "true"}}
    end
  end

  describe "retiring" do
    test "dry run reports the plan without writing" do
      seed("deleted", [])
      stub_manager([workspace("alive", "dalexandre")], admin())

      assert %{status: :dry_run, retired: ["deleted"]} = Reconciler.sweep(dry_run: true)
      assert status_of("deleted") == "running"
    end

    test "a retired record keeps its IDE-owned state and is hidden from the sidebar" do
      seed("deleted", [])
      {:ok, _} = State.set_mode("deleted", :manual)
      age_record("deleted")
      stub_manager([workspace("alive", "dalexandre")], admin())

      assert %{status: :ok, retired: ["deleted"]} = Reconciler.sweep(dry_run: false)

      {:ok, record} = MemoryAdapter.get("deleted")
      assert WorkspaceRecord.retired?(record)
      # Retire marks, never deletes — the operator's mode choice survives.
      assert record.mode == "manual"

      refute "deleted" in Enum.map(State.list(exclude_status: "stale"), & &1.external_id)
    end

    test "a recent State write defers retirement rather than racing it" do
      seed("deleted", [])
      # Any State write refreshes last_seen_at, so an operator touching the
      # record moves it back inside the grace window. That errs toward keeping
      # a record — the safe direction — and resolves itself on a later sweep.
      {:ok, _} = State.set_mode("deleted", :manual)
      stub_manager([workspace("alive", "dalexandre")], admin())

      assert %{status: :ok, retired: [], skipped: %{within_grace: 1}} =
               Reconciler.sweep(dry_run: false)

      age_record("deleted")
      assert %{status: :ok, retired: ["deleted"]} = Reconciler.sweep(dry_run: false)
    end

    test "recreating a workspace under the same id un-retires it" do
      seed("recycled", status: WorkspaceRecord.stale_status())

      {:ok, _} =
        State.sync(%Casein.Workspace{
          id: "recycled",
          name: "recycled",
          user: "dalexandre",
          status: :running
        })

      assert status_of("recycled") == "running"
    end

    test "emits an audit event naming why the record was retired" do
      seed("deleted", [])
      stub_manager([workspace("alive", "dalexandre")], admin())

      Reconciler.sweep(dry_run: false)

      assert Enum.any?(Casein.Audit.MemoryAdapter.list(), fn event ->
               event.action == "workspace.retired" and
                 event.workspace_id == "deleted" and
                 event.reason == :absent_from_source
             end)
    end

    @tag :tmp_dir
    test "a workspace still on disk is NOT retired though absent from the listing", %{
      tmp_dir: tmp_dir
    } do
      # The end-to-end form of the dry-run regression: a real directory that the
      # manager does not list must survive against the real File.dir?/1 guard.
      seed("on-disk", host_path: tmp_dir)
      stub_manager([workspace("alive", "dalexandre")], admin())

      assert %{status: :ok, retired: [], skipped: %{on_disk: 1}} =
               Reconciler.sweep(dry_run: false)

      assert status_of("on-disk") == "running"
    end
  end
end
