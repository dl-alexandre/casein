defmodule CaseinWeb.Plugs.NormalizeLegacyTmuxSessionTest do
  use CaseinWeb.ConnCase, async: false

  alias CaseinWeb.Plugs.NormalizeLegacyTmuxSession

  @legacy "devide_dalexandre-dev_u-dalexandre-gcmvgdxr"
  @canonical "casein_dalexandre-dev_u-dalexandre-gcmvgdxr"

  # Backend stub. Deliberately not `@behaviour Casein.Terminals.Backend`: the plug
  # calls only session_exists?/1, and declaring the behaviour would demand ~20
  # unrelated callbacks whose stubs would drown this file in warnings.
  defmodule FakeBackend do
    def session_exists?(session) do
      case Application.get_env(:casein, :__legacy_tmux_test_live__, []) do
        :raise -> raise "tmux unavailable"
        live -> session in live
      end
    end
  end

  setup do
    prev = Application.get_env(:casein, :terminal_backend)
    Application.put_env(:casein, :terminal_backend, FakeBackend)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:casein, :terminal_backend, prev),
        else: Application.delete_env(:casein, :terminal_backend)

      Application.delete_env(:casein, :__legacy_tmux_test_live__)
    end)

    :ok
  end

  defp live(names), do: Application.put_env(:casein, :__legacy_tmux_test_live__, names)

  defp run(session) do
    query = if session, do: "?tmux_session=#{URI.encode_www_form(session)}", else: ""

    :get
    |> Phoenix.ConnTest.build_conn("/api/preview/mcp" <> query)
    |> NormalizeLegacyTmuxSession.call([])
  end

  test "rewrites a legacy name to its live canonical twin" do
    live([@canonical])

    conn = run(@legacy)

    assert conn.query_params["tmux_session"] == @canonical
    assert conn.params["tmux_session"] == @canonical
  end

  test "leaves the legacy name alone when no canonical twin exists" do
    live([])

    assert run(@legacy).query_params["tmux_session"] == @legacy
  end

  test "leaves the legacy name alone when that session is itself still live" do
    # Both exist: rewriting would redirect the request onto a different session
    # than the one it named.
    live([@legacy, @canonical])

    assert run(@legacy).query_params["tmux_session"] == @legacy
  end

  test "leaves an already-canonical name untouched" do
    live([@canonical])

    assert run(@canonical).query_params["tmux_session"] == @canonical
  end

  test "passes through when no tmux_session param is present" do
    live([@canonical])

    refute Map.has_key?(run(nil).query_params, "tmux_session")
  end

  test "leaves the name alone when the backend cannot answer" do
    live(:raise)

    assert run(@legacy).query_params["tmux_session"] == @legacy
  end

  test "does not rewrite a bare legacy prefix with no session suffix" do
    live([@canonical, "casein_"])

    assert run("devide_").query_params["tmux_session"] == "devide_"
  end
end
