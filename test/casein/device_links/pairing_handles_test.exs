defmodule Casein.DeviceLinks.PairingHandlesTest do
  use Casein.DataCase, async: false

  alias Casein.Audit
  alias Casein.DeviceLinks
  alias Casein.DeviceLinks.PairingHandle
  alias Casein.Workspace

  @origin "https://casein.devbox.milcgroup.com"
  @audience "casein_mobile"

  defmodule OwnedSource do
    def get(id, _auth),
      do: {:ok, %Workspace{id: id, name: "Workspace #{id}", user: "owner", status: :running}}
  end

  setup do
    previous_source = Application.get_env(:casein, :workspace_source)
    previous_canonical = Application.get_env(:casein, :canonical_public_origin)
    previous_ttl = Application.get_env(:casein, :device_link_pairing_handle_ttl_seconds)

    previous_issue_limit =
      Application.get_env(:casein, :device_link_pairing_handle_issue_limit)

    Application.put_env(:casein, :workspace_source, OwnedSource)
    Application.put_env(:casein, :canonical_public_origin, @origin)
    Audit.clear()
    reset_rate_limits()

    on_exit(fn ->
      restore(:workspace_source, previous_source)
      restore(:canonical_public_origin, previous_canonical)
      restore(:device_link_pairing_handle_ttl_seconds, previous_ttl)
      restore(:device_link_pairing_handle_issue_limit, previous_issue_limit)
    end)

    :ok
  end

  test "server-owned handle exchanges once and audits without the raw handle" do
    {:ok, pending} = issue()

    assert {:ok, result} = exchange(pending.handle)
    assert result.workspace.id == "ws-1"
    assert result.link.subject_id == "owner"
    assert result.link.origin_id == Casein.Origin.id()
    assert {:ok, %{workspace_id: "ws-1"}} = DeviceLinks.verify_token(result.token)

    assert {:error, :pairing_handle_replayed} = exchange(pending.handle)

    events = Audit.list()
    serialized = inspect(events)
    refute serialized =~ pending.handle
    refute serialized =~ result.token
    assert Enum.any?(events, &(&1.action == "mobile.pairing_handle.issued"))
    assert Enum.any?(events, &(&1.action == "mobile.pairing_handle.exchanged"))

    assert Enum.any?(
             events,
             &(&1.action == "mobile.pairing_handle.rejected" and
                 &1.reason == :pairing_handle_replayed)
           )
  end

  test "tampering, wrong origin, workspace, subject, and audience fail without consuming" do
    {:ok, pending} = issue()

    replacement = if String.first(pending.handle) == "A", do: "B", else: "A"
    tampered = replacement <> binary_part(pending.handle, 1, byte_size(pending.handle) - 1)
    assert {:error, :invalid_pairing_handle} = exchange(tampered)

    assert {:error, :origin_mismatch} =
             DeviceLinks.exchange_pairing_handle(pending.handle, "https://other.example", %{
               "origin" => "https://other.example",
               "audience" => @audience
             })

    assert {:error, :resource_mismatch} =
             exchange(pending.handle, %{"workspace_id" => "ws-other"})

    assert {:error, :unauthorized} =
             exchange(pending.handle, %{"subject_id" => "other-user"})

    assert {:error, :pairing_handle_audience_mismatch} =
             exchange(pending.handle, %{"audience" => "other-client"})

    assert {:ok, _result} = exchange(pending.handle)
  end

  test "refresh revokes the stale QR while keeping the newest handle usable" do
    {:ok, first} = issue()
    {:ok, second} = issue()

    assert first.handle != second.handle
    assert {:error, :pairing_handle_revoked} = exchange(first.handle)
    assert {:ok, _result} = exchange(second.handle)
  end

  test "concurrent refreshes serialize so exactly one newest handle remains usable" do
    owner = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          receive do
            :go -> issue()
          end
        end)
      end

    Enum.each(tasks, fn task ->
      Ecto.Adapters.SQL.Sandbox.allow(Repo, owner, task.pid)
      send(task.pid, :go)
    end)

    pending =
      tasks
      |> Enum.map(&Task.await(&1, 5_000))
      |> Enum.map(fn {:ok, result} -> result end)

    results = Enum.map(pending, &exchange(&1.handle))

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, :pairing_handle_revoked}, &1)) == 1
  end

  test "expired handles fail closed" do
    {:ok, pending} = issue()

    PairingHandle
    |> Repo.get_by!(handle_hash: DeviceLinks.token_hash(pending.handle))
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert {:error, :pairing_handle_expired} = exchange(pending.handle)
  end

  test "concurrent scans produce exactly one durable credential" do
    {:ok, pending} = issue()
    owner = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          receive do
            :go -> exchange(pending.handle)
          end
        end)
      end

    Enum.each(tasks, fn task ->
      Ecto.Adapters.SQL.Sandbox.allow(Repo, owner, task.pid)
      send(task.pid, :go)
    end)

    results = Enum.map(tasks, &Task.await(&1, 5_000))

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, :pairing_handle_replayed}, &1)) == 1
  end

  test "invalid handle shapes and enumeration guesses have one generic failure" do
    for handle <- ["", "short", String.duplicate("a", 42), String.duplicate("!", 43)] do
      assert {:error, :invalid_pairing_handle} = exchange(handle)
    end

    unknown = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    assert {:error, :invalid_pairing_handle} = exchange(unknown)
  end

  test "authenticated issuance is rate limited per origin, user, and workspace" do
    Application.put_env(:casein, :device_link_pairing_handle_issue_limit, 1)

    assert {:ok, _pending} = issue()
    assert {:error, :rate_limited} = issue()
  end

  defp issue do
    DeviceLinks.issue_pairing_handle(owner(), "ws-1", @origin)
  end

  defp exchange(handle, overrides \\ %{}) do
    attrs =
      %{
        "origin" => @origin,
        "audience" => @audience,
        "device_name" => "Test device",
        "platform" => "mobile"
      }
      |> Map.merge(overrides)

    DeviceLinks.exchange_pairing_handle(handle, @origin, attrs)
  end

  defp owner do
    %{id: "owner", username: "owner", email: "owner@example.com", role: :owner}
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, value), do: Application.put_env(:casein, key, value)

  defp reset_rate_limits do
    case :ets.whereis(Casein.RateLimit) do
      :undefined -> :ok
      _table -> :ets.delete_all_objects(Casein.RateLimit)
    end
  end
end
