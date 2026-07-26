defmodule Casein.Deployment.OperatorConfigTest do
  use ExUnit.Case, async: true

  alias Casein.Deployment.OperatorConfig

  @repo_root Path.expand("../../..", __DIR__)

  test "parses the complete data-only operator contract" do
    assert {:ok, config} =
             OperatorConfig.parse(%{
               "contract_version" => 1,
               "deployment_capabilities" => [
                 "socket",
                 "reverse_proxy",
                 "deploy_drift",
                 "deploy_status",
                 "poller"
               ],
               "deployment" => %{
                 "default_host" => "ide.example.com",
                 "deploy_service" => "example-deploy.service",
                 "git_branch" => "stable",
                 "git_credential_helper" => "example-credential-helper",
                 "git_remote" => "https://example.com/acme/casein.git",
                 "github_repo" => "acme/casein",
                 "last_deploy_path" => "/run/example/last-deploy.json",
                 "ls_remote_timeout_ms" => 4_000,
                 "phase_stale_in_progress_ms" => %{"activate" => 600_000},
                 "poller_watch_interval_ms" => 30_000,
                 "remote_head_cache_ttl_ms" => 60_000,
                 "stale_in_progress_ms" => 2_700_000
               }
             })

    assert config[:contract_version] == OperatorConfig.contract_version()

    assert config[:deployment_capabilities] == [
             :socket,
             :reverse_proxy,
             :deploy_drift,
             :deploy_status,
             :poller
           ]

    assert config[:deployment][:default_host] == "ide.example.com"
    assert config[:deployment][:git_branch] == "stable"
    assert config[:deployment][:phase_stale_in_progress_ms] == %{"activate" => 600_000}
  end

  test "allows either section to be omitted" do
    assert {:ok, []} = OperatorConfig.parse(%{})

    assert {:ok, [deployment_capabilities: []]} =
             OperatorConfig.parse(%{"deployment_capabilities" => []})

    assert {:ok, [deployment: [git_branch: "main"]]} =
             OperatorConfig.parse(%{"deployment" => %{"git_branch" => "main"}})
  end

  test "an overlay does not inherit site-specific values from core" do
    core_config = [
      default_host: "private.example",
      deploy_service: "private-deploy.service",
      git_branch: "private-release",
      git_credential_helper: "private-helper",
      git_remote: "https://private.example/repo.git",
      github_repo: "private/repo",
      github_webhook_secret: "private-secret",
      last_deploy_path: "/run/private/deploy.json",
      ls_remote_timeout_ms: 5_000
    ]

    assert OperatorConfig.deployment(core_config, []) == [ls_remote_timeout_ms: 5_000]
    assert OperatorConfig.deployment_capabilities([]) == []

    operator_config = [
      deployment_capabilities: [:deploy_status],
      deployment: [git_branch: "stable", last_deploy_path: "/run/acme/deploy.json"]
    ]

    assert OperatorConfig.deployment(core_config, operator_config) == [
             git_branch: "stable",
             last_deploy_path: "/run/acme/deploy.json",
             ls_remote_timeout_ms: 5_000
           ]

    assert OperatorConfig.deployment_capabilities(operator_config) == [:deploy_status]
  end

  test "rejects unknown keys and capabilities without creating atoms" do
    assert {:error, {:unknown_keys, :root, ["private_extension"]}} =
             OperatorConfig.parse(%{"private_extension" => true})

    assert {:error, {:unknown_keys, :deployment, ["shell_command"]}} =
             OperatorConfig.parse(%{"deployment" => %{"shell_command" => "whoami"}})

    assert {:error, {:unknown_capability, "arbitrary_system_access"}} =
             OperatorConfig.parse(%{
               "deployment_capabilities" => ["arbitrary_system_access"]
             })
  end

  test "rejects empty strings and non-positive timeouts" do
    assert {:error, {:invalid_value, [:deployment, "git_remote"], "non-empty string"}} =
             OperatorConfig.parse(%{"deployment" => %{"git_remote" => ""}})

    assert {:error, {:invalid_value, [:deployment, "ls_remote_timeout_ms"], "positive integer"}} =
             OperatorConfig.parse(%{"deployment" => %{"ls_remote_timeout_ms" => 0}})
  end

  test "rejects unsupported contract versions" do
    assert {:error, {:unsupported_contract_version, 2, 1}} =
             OperatorConfig.parse(%{"contract_version" => 2})
  end

  test "loads JSON from a file and raises with an actionable error" do
    path =
      Path.join(
        System.tmp_dir!(),
        "casein-operator-config-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)

    File.write!(path, Jason.encode!(%{"deployment" => %{"git_branch" => "main"}}))

    assert {:ok, [deployment: [git_branch: "main"]]} = OperatorConfig.load(path)

    File.write!(path, ~s({"deployment":{"git_branch":""}}))

    assert_raise ArgumentError, ~r/deployment.git_branch must be a non-empty string/, fn ->
      OperatorConfig.load!(path)
    end
  end

  test "the public example satisfies the current contract" do
    assert {:ok, public_config} =
             OperatorConfig.load(Path.join(@repo_root, "config/operator.example.json"))

    assert public_config[:contract_version] == OperatorConfig.contract_version()
    assert :socket in OperatorConfig.deployment_capabilities(public_config)
  end
end
