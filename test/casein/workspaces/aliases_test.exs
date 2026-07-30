defmodule Casein.Workspaces.AliasesTest do
  use Casein.TestCase, async: true

  alias Casein.Workspaces.Aliases

  test "folder_id_for_path/1 encodes absolute paths" do
    assert Aliases.folder_id_for_path("/data/workspaces/dalexandre/casein") ==
             "folder:L2RhdGEvd29ya3NwYWNlcy9kYWxleGFuZHJlL2Nhc2Vpbg"
  end

  test "linked?/2 matches folder ids for the same path" do
    left = Aliases.folder_id_for_path("/tmp/casein_aliases")
    right = Aliases.folder_id_for_path("/tmp/casein_aliases")

    assert Aliases.linked?(left, right)
    refute Aliases.linked?(left, Aliases.folder_id_for_path("/tmp/other"))
  end

  test "viewer_ids/2 always includes the folder id for folder workspaces" do
    path = "/tmp/casein_aliases_viewer"
    folder_id = Aliases.folder_id_for_path(path)

    assert folder_id in Aliases.viewer_ids(folder_id, resolve_remote?: true)
  end

  test "viewer_ids/2 returns the input ID when no linked workspaces exist" do
    ids = Aliases.viewer_ids("some-unknown-workspace-id", resolve_remote?: true)
    assert "some-unknown-workspace-id" in ids
  end

  describe "viewer_ids/2 resolve_remote? gating" do
    # Regression for the PreviewPanes cascade: broadcasting from the singleton
    # must resolve viewer aliases WITHOUT a synchronous Manager HTTP call, since
    # a cold-State fallthrough would crash the named process under CI contention.
    setup do
      test = self()

      # Replace the default Manager stub (installed by Casein.TestCase) with one
      # that reports every call, so we can prove whether HTTP was attempted.
      Req.Test.stub(Casein.Integrations.Manager.Client, fn conn ->
        send(test, {:manager_called, conn.request_path})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
      end)

      # A cold workspace: not a folder id, no persisted State record, so alias
      # resolution reaches the Workspaces.get fallthrough.
      %{cold_id: "cold-ws-#{System.unique_integer([:positive])}"}
    end

    test "resolve_remote?: false degrades to the canonical id with no HTTP", %{cold_id: cold_id} do
      assert Aliases.viewer_ids(cold_id, resolve_remote?: false) == [cold_id]
      # The Manager stub was never touched — the fan-out stayed in-process.
      refute_received {:manager_called, _}
    end

    test "resolve_remote?: true reaches the Manager for a cold id", %{
      cold_id: cold_id
    } do
      assert cold_id in Aliases.viewer_ids(cold_id, resolve_remote?: true)
      assert_received {:manager_called, _}
    end
  end
end
