defmodule Casein.Deployment.GithubWebhookTest do
  use Casein.TestCase, async: true

  alias Casein.Deployment.GithubWebhook

  @secret "webhook-test-secret"
  @repo "dl-alexandre/casein"

  test "verify_signature accepts a valid GitHub HMAC" do
    body = ~s({"ref":"refs/heads/master"})
    signature = sign(body, @secret)

    assert :ok = GithubWebhook.verify_signature(body, signature, @secret)
  end

  test "verify_signature rejects missing and invalid signatures" do
    body = ~s({"ref":"refs/heads/master"})

    assert {:error, :missing_signature} = GithubWebhook.verify_signature(body, nil, @secret)

    assert {:error, :invalid_signature} =
             GithubWebhook.verify_signature(body, "sha256=deadbeef", @secret)
  end

  test "master_push? accepts a master push on the expected repository" do
    payload = %{
      "ref" => "refs/heads/master",
      "repository" => %{"full_name" => @repo}
    }

    assert :ok = GithubWebhook.master_push?(payload)
  end

  test "master_push? ignores deleted branches and non-master refs" do
    assert {:ignore, "branch_deleted"} =
             GithubWebhook.master_push?(%{"ref" => "refs/heads/master", "deleted" => true})

    assert {:ignore, "non_deploy_branch:" <> _} =
             GithubWebhook.master_push?(%{
               "ref" => "refs/heads/feature/x",
               "repository" => %{"full_name" => @repo}
             })
  end

  test "master_push? can require the configured repository" do
    prev_deploy = Application.get_env(:casein, :deployment)

    Application.put_env(
      :casein,
      :deployment,
      (prev_deploy || []) |> Keyword.put(:github_repo, @repo)
    )

    on_exit(fn ->
      if prev_deploy,
        do: Application.put_env(:casein, :deployment, prev_deploy),
        else: Application.delete_env(:casein, :deployment)
    end)

    assert {:ignore, "unexpected_repo:other/repo,expected:" <> _} =
             GithubWebhook.master_push?(%{
               "ref" => "refs/heads/master",
               "repository" => %{"full_name" => "other/repo"}
             })
  end

  defp sign(body, secret) do
    "sha256=" <> (:crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower))
  end
end
