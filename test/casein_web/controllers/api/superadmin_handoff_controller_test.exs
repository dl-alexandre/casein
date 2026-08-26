defmodule CaseinWeb.API.SuperadminHandoffControllerTest do
  use CaseinWeb.ConnCase, async: false

  alias Casein.Workspace
  alias Casein.Workspaces.State.MemoryAdapter

  @token "test-superadmin-handoff-token"
  @secret "test-superadmin-handoff-secret"
  @workspace_id "workspace-123"
  @session Casein.Terminals.Tmux.session_name(@workspace_id, "v3-abcd1234")

  defmodule Source do
    def get(id, _auth),
      do: {:ok, %Workspace{id: id, name: id, user: "operator", path: "/tmp", status: :running}}

    def safe_host_path(_workspace), do: {:ok, "/tmp"}
    def safe_host_loc(_workspace), do: {:ok, {:local, "/tmp"}}
  end

  defmodule Adapter do
    defdelegate ensure_session(session, cwd), to: Casein.Test.FakeTmuxAdapter
    defdelegate list_sessions(), to: Casein.Test.FakeTmuxAdapter
    defdelegate session_exists?(session), to: Casein.Test.FakeTmuxAdapter
    defdelegate set_session_alias(session, name), to: Casein.Test.FakeTmuxAdapter

    def set_session_actor(session, actor) do
      pid = TmuxCtl.Test.FakeState.get(:fake_tmux_test_pid, self())
      send(pid, {:fake_tmux_set_session_actor, session, actor})
      :ok
    end
  end

  setup %{conn: conn} do
    keys = [
      :api_token,
      :superadmin_handoff_secret,
      :forward_auth_email_domain,
      :workspace_source,
      :workspace_state_adapter,
      :tmux_adapter
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:casein, &1)})

    previous_fake = %{
      pid: TmuxCtl.Test.FakeState.get(:fake_tmux_test_pid),
      windows: TmuxCtl.Test.FakeState.get(:fake_tmux_windows),
      meta: TmuxCtl.Test.FakeState.get(:fake_tmux_session_meta)
    }

    MemoryAdapter.clear()
    Application.put_env(:casein, :api_token, @token)
    Application.put_env(:casein, :superadmin_handoff_secret, @secret)
    Application.put_env(:casein, :forward_auth_email_domain, "milcgroup.com")
    Application.put_env(:casein, :workspace_source, Source)
    Application.put_env(:casein, :workspace_state_adapter, MemoryAdapter)
    Application.put_env(:casein, :tmux_adapter, Adapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())
    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{@session => []})
    TmuxCtl.Test.FakeState.put(:fake_tmux_session_meta, %{@session => %{actor: "operator"}})

    on_exit(fn ->
      MemoryAdapter.clear()
      Enum.each(previous, &restore_env/1)
      restore_fake(:fake_tmux_test_pid, previous_fake.pid)
      restore_fake(:fake_tmux_windows, previous_fake.windows)
      restore_fake(:fake_tmux_session_meta, previous_fake.meta)
    end)

    {:ok, conn: conn}
  end

  test "creates a V3 session with the requested familiar label", %{conn: conn} do
    label = "DevBox · Operator · V3"

    conn =
      conn
      |> authed()
      |> post("/api/superadmin/session", %{
        "kind" => "v3",
        "workspace_id" => @workspace_id,
        "label" => label
      })

    payload = json_response(conn, 200)
    assert payload["session"]["session_alias"] == label
    assert payload["session"]["actor"] == "operator"
    assert_receive {:fake_tmux_set_session_actor, _session, "operator"}
    assert_receive {:fake_tmux_set_session_alias, session, ^label}
    assert String.starts_with?(session, "casein_#{@workspace_id}_v3-")
  end

  test "renames only a session owned by the asserted operator", %{conn: conn} do
    label = "Release shell"

    conn =
      conn
      |> authed()
      |> patch(
        "/api/superadmin/session/#{URI.encode_www_form(@session)}/name",
        %{"workspace_id" => @workspace_id, "label" => label}
      )

    payload = json_response(conn, 200)
    assert payload["session"]["session_alias"] == label
    assert_receive {:fake_tmux_set_session_alias, @session, ^label}
  end

  test "rejects blank or oversized labels", %{conn: conn} do
    conn =
      conn
      |> authed()
      |> patch(
        "/api/superadmin/session/#{URI.encode_www_form(@session)}/name",
        %{"workspace_id" => @workspace_id, "label" => String.duplicate("x", 81)}
      )

    assert json_response(conn, 422) == %{"error" => "invalid_session_alias"}
    refute_receive {:fake_tmux_set_session_alias, _, _}
  end

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("x-onebackend-actor-assertion", actor_assertion())
  end

  defp actor_assertion do
    now = System.system_time(:second)

    payload = %{
      "kind" => "onebackend_superadmin_actor",
      "email" => "operator@milcgroup.com",
      "workspace_id" => @workspace_id,
      "iat" => now,
      "exp" => now + 60
    }

    encoded = payload |> Jason.encode!() |> Base.url_encode64(padding: false)
    signature = :crypto.mac(:hmac, :sha256, @secret, encoded)
    encoded <> "." <> Base.url_encode64(signature, padding: false)
  end

  defp restore_env({key, nil}), do: Application.delete_env(:casein, key)
  defp restore_env({key, value}), do: Application.put_env(:casein, key, value)

  defp restore_fake(key, nil), do: TmuxCtl.Test.FakeState.delete(key)
  defp restore_fake(key, value), do: TmuxCtl.Test.FakeState.put(key, value)
end
