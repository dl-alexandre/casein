defmodule DevIDE.Deployment.LastDeployTest do
  use DevIDE.TestCase, async: true

  alias DevIDE.Deployment.LastDeploy

  @deployed "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  @remote "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  @target @remote

  defp write_status!(path, attrs) do
    File.mkdir_p!(Path.dirname(path))

    record =
      Map.merge(
        %{
          "outcome" => "failed",
          "target_sha" => @target,
          "target_short" => String.slice(@target, 0, 12),
          "from_sha" => @deployed,
          "phase" => "gate",
          "reason" => "pre-push gate failed",
          "started_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "finished_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        },
        attrs
      )

    tmp = path <> ".tmp"
    File.write!(tmp, Jason.encode!(record) <> "\n")
    File.rename!(tmp, path)
  end

  test "assess returns failed when the poller aborted on the remote head" do
    record = %{
      "outcome" => "failed",
      "target_sha" => @target,
      "phase" => "gate",
      "reason" => "pre-push gate failed"
    }

    assert {:failed, %{phase: "gate", target_short: _}} =
             LastDeploy.assess(@deployed, {:ok, @remote}, record)
  end

  test "assess returns in_progress for an active deploy of the remote head" do
    record = %{
      "outcome" => "in_progress",
      "target_sha" => @target,
      "phase" => "build",
      "started_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    assert {:in_progress, %{target_sha: target_sha, message: message}} =
             LastDeploy.assess(@deployed, {:ok, @remote}, record)

    assert target_sha == @target
    assert message =~ "Building release"
    assert message =~ String.slice(@target, 0, 12)
  end

  test "in_progress messages include elapsed minutes once deploy has been running" do
    started_at =
      DateTime.utc_now()
      |> DateTime.add(-185, :second)
      |> DateTime.to_iso8601()

    record = %{
      "outcome" => "in_progress",
      "target_sha" => @target,
      "phase" => "gate",
      "started_at" => started_at
    }

    assert {:in_progress, %{message: message}} =
             LastDeploy.assess(@deployed, {:ok, @remote}, record)

    assert message =~ "Running pre-push gate"
    assert message =~ "3m"
  end

  test "assess ignores stale in_progress records" do
    record = %{
      "outcome" => "in_progress",
      "target_sha" => @target,
      "started_at" => "2020-01-01T00:00:00Z"
    }

    assert :idle = LastDeploy.assess(@deployed, {:ok, @remote}, record)
  end

  test "assess treats activation records as stale before long build records" do
    started_at =
      DateTime.utc_now()
      |> DateTime.add(-700, :second)
      |> DateTime.to_iso8601()

    activate_record = %{
      "outcome" => "in_progress",
      "target_sha" => @target,
      "phase" => "activate",
      "started_at" => started_at
    }

    build_record = %{activate_record | "phase" => "build"}

    assert :idle = LastDeploy.assess(@deployed, {:ok, @remote}, activate_record)
    assert {:in_progress, _info} = LastDeploy.assess(@deployed, {:ok, @remote}, build_record)
  end

  test "assess returns idle when the target already matches the running revision" do
    record = %{"outcome" => "failed", "target_sha" => @deployed, "phase" => "gate"}

    assert :idle = LastDeploy.assess(@deployed, {:ok, @remote}, record)
  end

  test "banner_status reads the configured status file" do
    path =
      Path.join(
        System.tmp_dir!(),
        "last-deploy-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)
    write_status!(path, %{})

    assert {:failed, %{reason: "pre-push gate failed"}} =
             LastDeploy.banner_status(
               path: path,
               deployed: @deployed,
               remote_head: {:ok, @remote}
             )
  end

  test "summary marks pipeline failed for actionable gate failures" do
    path =
      Path.join(
        System.tmp_dir!(),
        "last-deploy-summary-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)
    write_status!(path, %{})

    assert %{pipeline: :failed, actionable: true, record: %{"outcome" => "failed"}} =
             LastDeploy.summary(
               path: path,
               deployed: @deployed,
               remote_head: {:ok, @remote}
             )
  end

  test "check_async is a no-op when DEV_IDE_DEPLOY_POLLER_WATCH disables it" do
    prev = System.get_env("DEV_IDE_DEPLOY_POLLER_WATCH")
    System.put_env("DEV_IDE_DEPLOY_POLLER_WATCH", "0")
    on_exit(fn -> restore_env("DEV_IDE_DEPLOY_POLLER_WATCH", prev) end)

    assert :ok = LastDeploy.check_async()
  end

  test "check_and_broadcast emits deploy_failure for actionable failures" do
    path =
      Path.join(
        System.tmp_dir!(),
        "last-deploy-broadcast-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)
    write_status!(path, %{})

    prev_deploy = Application.get_env(:dev_ide, :deployment)

    Application.put_env(
      :dev_ide,
      :deployment,
      Keyword.put(prev_deploy || [], :last_deploy_path, path)
    )

    on_exit(fn ->
      if prev_deploy,
        do: Application.put_env(:dev_ide, :deployment, prev_deploy),
        else: Application.delete_env(:dev_ide, :deployment)
    end)

    prev_rev = System.get_env("DEVIDE_GIT_REVISION")
    System.put_env("DEVIDE_GIT_REVISION", @deployed)
    on_exit(fn -> restore_env("DEVIDE_GIT_REVISION", prev_rev) end)

    Phoenix.PubSub.subscribe(DevIde.PubSub, "deploy:updates")

    assert :failed = LastDeploy.check_and_broadcast(remote_head: {:ok, @remote})
    assert_receive {:deploy_failure, %{phase: "gate"}}
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
