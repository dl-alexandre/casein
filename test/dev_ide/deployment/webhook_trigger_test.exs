defmodule Casein.Deployment.WebhookTriggerTest do
  use Casein.TestCase, async: false

  alias Casein.Deployment.WebhookTrigger

  @repo "dl-alexandre/dev_ide"

  setup do
    prev_trigger = Application.get_env(:casein, :deploy_poller_trigger)
    parent = self()

    Application.put_env(:casein, :deploy_poller_trigger, fn _opts ->
      send(parent, :poller_triggered)
      :ok
    end)

    on_exit(fn ->
      if prev_trigger,
        do: Application.put_env(:casein, :deploy_poller_trigger, prev_trigger),
        else: Application.delete_env(:casein, :deploy_poller_trigger)
    end)

    :ok
  end

  test "handle triggers the poller for master push events" do
    payload = %{
      "ref" => "refs/heads/master",
      "repository" => %{"full_name" => @repo}
    }

    assert :ok = WebhookTrigger.handle("push", payload)
    assert_receive :poller_triggered
  end

  test "handle ignores ping and non-master pushes" do
    assert {:ignored, "ping"} = WebhookTrigger.handle("ping", %{})

    assert {:ignored, "non_deploy_branch:" <> _} =
             WebhookTrigger.handle("push", %{
               "ref" => "refs/heads/feature",
               "repository" => %{"full_name" => @repo}
             })
  end

  test "handle surfaces poller trigger failures" do
    Application.put_env(:casein, :deploy_poller_trigger, fn _opts ->
      {:error, :nope}
    end)

    payload = %{
      "ref" => "refs/heads/master",
      "repository" => %{"full_name" => @repo}
    }

    assert {:error, :nope} = WebhookTrigger.handle("push", payload)
  end
end
