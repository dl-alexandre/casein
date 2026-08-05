defmodule Casein.Terminals.SessionArchiveDispositionTest do
  use Casein.TestCase, async: false

  alias Casein.Terminals.Session

  defmodule Holder do
    use GenServer

    def start_link({workspace, sid, disposition}) do
      GenServer.start_link(__MODULE__, disposition, name: Session.via(workspace, sid))
    end

    @impl true
    def init(disposition), do: {:ok, disposition}

    @impl true
    def handle_call(:archive_disposition, _from, disposition) do
      {:reply, disposition, disposition}
    end
  end

  test "active process reuse rejects ordinary to ephemeral disposition changes" do
    workspace = "archive-active"
    sid = "mob-client-chosen"
    pid = start_supervised!({Holder, {workspace, sid, :persistent}})

    assert {:ok, ^pid} = Session.ensure_started(workspace, sid, {:local, "/tmp"})

    assert {:error, :archive_disposition_mismatch} =
             Session.ensure_started(workspace, sid, {:local, "/tmp"}, archive: :ephemeral)
  end

  test "restored ephemeral process rejects fallback to persistent disposition" do
    workspace = "archive-restored"
    sid = "server-owned"
    pid = start_supervised!({Holder, {workspace, sid, :ephemeral}})

    assert {:ok, ^pid} =
             Session.ensure_started(workspace, sid, {:local, "/tmp"}, archive: :ephemeral)

    assert {:error, :archive_disposition_mismatch} =
             Session.ensure_started(workspace, sid, {:local, "/tmp"})
  end

  test "invalid archive disposition fails before process creation" do
    assert {:error, :invalid_archive_disposition} =
             Session.ensure_started("archive-invalid", "sid", {:local, "/tmp"}, archive: :disk)

    assert :error = Session.whereis("archive-invalid", "sid")
  end
end
