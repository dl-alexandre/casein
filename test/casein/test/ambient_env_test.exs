defmodule Casein.Test.AmbientEnvTest do
  @moduledoc """
  Coverage for the operator-env scrub used by test_helper (#248).
  """
  use ExUnit.Case, async: false

  alias Casein.Test.AmbientEnv

  @leak_vars ~w(
    CASEIN_ON_DEVBOX
    CASEIN_HTTP_SOCKET
    CASEIN_INSTANCE_UUID
    CASEIN_API_TOKEN
    CASEIN_WORKSPACE_API_TOKENS
    CASEIN_WORKSPACES_ROOT
    CASEIN_AGENT_WORKTREE_ROOTS
    CASEIN_GROK_BUNDLE_ROOT
    CASEIN_GROK_LEADER_ROOT
    CASEIN_FORWARD_AUTH
    CASEIN_ADMINS
    CASEIN_TMUX_HOST_SHELL
    CASEIN_PREVIEW_PROXY
    CASEIN_NPM_PREFIX
    CASEIN_DEVBOX_EXEC_SERVICE
    CASEIN_GIT_REVISION
  )

  setup do
    previous =
      for key <- @leak_vars ++ keep_probe_vars() do
        {key, System.get_env(key)}
      end

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  test "scrub! drops operator CASEIN_* exports that product code reads" do
    Enum.each(@leak_vars, &System.put_env(&1, "ambient-leak"))

    deleted = AmbientEnv.scrub!()

    for key <- @leak_vars do
      assert key in deleted, "#{key} should have been scrubbed"
      assert System.get_env(key) == nil
    end
  end

  test "scrub! keeps harness CASEIN_TEST_* / CASEIN_GATE_* / CASEIN_REPO_ADAPTER" do
    System.put_env("CASEIN_REPO_ADAPTER", "postgres")
    System.put_env("CASEIN_TEST_TMPDIR", "/tmp/casein-test-tmp")
    System.put_env("CASEIN_TEST_FIXTURE_MARK", "keep-me")
    System.put_env("CASEIN_GATE_SKIP_PORTABLE", "1")
    System.put_env("CASEIN_ON_DEVBOX", "true")

    deleted = AmbientEnv.scrub!()

    assert "CASEIN_ON_DEVBOX" in deleted
    assert System.get_env("CASEIN_ON_DEVBOX") == nil

    assert System.get_env("CASEIN_REPO_ADAPTER") == "postgres"
    assert System.get_env("CASEIN_TEST_TMPDIR") == "/tmp/casein-test-tmp"
    assert System.get_env("CASEIN_TEST_FIXTURE_MARK") == "keep-me"
    assert System.get_env("CASEIN_GATE_SKIP_PORTABLE") == "1"

    refute "CASEIN_REPO_ADAPTER" in deleted
    refute "CASEIN_TEST_TMPDIR" in deleted
    refute "CASEIN_TEST_FIXTURE_MARK" in deleted
    refute "CASEIN_GATE_SKIP_PORTABLE" in deleted
  end

  test "keep?/1 documents the harness allowlist" do
    assert AmbientEnv.keep?("CASEIN_REPO_ADAPTER")
    assert AmbientEnv.keep?("CASEIN_TEST_TMPDIR")
    assert AmbientEnv.keep?("CASEIN_TEST_REPO")
    assert AmbientEnv.keep?("CASEIN_GATE_SKIP_FORMAT")
    refute AmbientEnv.keep?("CASEIN_ON_DEVBOX")
    refute AmbientEnv.keep?("CASEIN_API_TOKEN")
    refute AmbientEnv.keep?("CASEIN_HTTP_SOCKET")
    refute AmbientEnv.casein_var?("HOME")
    assert AmbientEnv.casein_var?("CASEIN_FOO")
  end

  test "suite boot left operator host knobs absent" do
    # test_helper.exs already ran scrub!/0. These are the vars verified ambient
    # on this box tonight; none may remain for product code to inherit.
    for key <- @leak_vars do
      assert System.get_env(key) == nil,
             "#{key} leaked into the test VM — extend AmbientEnv.scrub!/0"
    end
  end

  defp keep_probe_vars do
    ~w(
      CASEIN_REPO_ADAPTER
      CASEIN_TEST_TMPDIR
      CASEIN_TEST_FIXTURE_MARK
      CASEIN_GATE_SKIP_PORTABLE
    )
  end
end
