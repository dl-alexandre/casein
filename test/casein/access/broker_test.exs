defmodule Casein.Access.BrokerTest do
  use ExUnit.Case, async: true

  alias Casein.Access.{Broker, Endpoint}

  defp ep(kind, url, opts \\ []) do
    Endpoint.new(
      kind: kind,
      base_url: url,
      auth: Keyword.get(opts, :auth, :session),
      scope: Keyword.get(opts, :scope, :any),
      advertised?: true
    )
  end

  describe "ordering" do
    test "prefers loopback, then lan, then tailscale, then public https" do
      endpoints = [
        ep(:public_https, "https://public.example", auth: :bearer),
        ep(:tailscale, "http://box.tailnet", scope: :same_tailnet),
        ep(:loopback, "http://127.0.0.1:4000", scope: :same_host),
        ep(:lan, "http://box.lan", scope: :same_lan)
      ]

      kinds =
        endpoints
        |> Broker.select(%{
          same_host?: true,
          same_lan?: true,
          on_tailnet?: true,
          has_session?: true,
          has_bearer?: true
        })
        |> Enum.map(& &1.kind)

      assert kinds == [:loopback, :lan, :tailscale, :public_https]
    end
  end

  describe "scope filtering (before probing)" do
    test "a phone off the tailnet never gets the magicdns door" do
      endpoints = [
        ep(:tailscale, "http://box.tailnet", scope: :same_tailnet),
        ep(:public_https, "https://public.example", auth: :bearer)
      ]

      selected = Broker.select(endpoints, %{on_tailnet?: false, has_bearer?: true})

      assert Enum.map(selected, & &1.kind) == [:public_https]
    end

    test "a remote client never gets the loopback door" do
      endpoints = [ep(:loopback, "http://127.0.0.1:4000", scope: :same_host)]
      assert Broker.select(endpoints, %{same_host?: false}) == []
    end
  end

  describe "auth filtering" do
    test "a client without a bearer does not get a bearer-only door" do
      endpoints = [ep(:public_https, "https://public.example", auth: :bearer)]
      assert Broker.select(endpoints, %{has_bearer?: false}) == []
    end

    test "absent credential context is permissive" do
      endpoints = [ep(:public_https, "https://public.example", auth: :bearer)]
      assert length(Broker.select(endpoints, %{})) == 1
    end
  end

  describe "an empty result is explainable, not silent" do
    test "select/2 with no context legitimately returns [] because every door is scoped" do
      endpoints = [
        ep(:loopback, "http://127.0.0.1:4000", scope: :same_host),
        ep(:tailscale, "http://box.tailnet", scope: :same_tailnet)
      ]

      assert Broker.select(endpoints, %{}) == [],
             "an empty context claims to be nowhere; guessing reachability is the flap"
    end

    test "select_with_reasons/2 says WHY each door was dropped" do
      endpoints = [
        ep(:loopback, "http://127.0.0.1:4000", scope: :same_host),
        ep(:public_https, "https://public.example", auth: :bearer)
      ]

      {selected, dropped} =
        Broker.select_with_reasons(endpoints, %{same_host?: false, has_bearer?: false})

      assert selected == []

      reasons = Enum.map(dropped, fn {endpoint, reason} -> {endpoint.kind, reason} end)
      assert {:loopback, {:scope_not_satisfied, :same_host}} in reasons
      assert {:public_https, {:auth_not_held, :bearer}} in reasons
    end

    test "reasons distinguish a scope miss from an auth miss" do
      endpoints = [ep(:public_https, "https://public.example", auth: :bearer)]

      {[], [{_endpoint, reason}]} =
        Broker.select_with_reasons(endpoints, %{has_bearer?: false})

      assert reason == {:auth_not_held, :bearer},
             "an auth problem reported as a scope problem sends the operator the wrong way"
    end

    test "select/2 and select_with_reasons/2 agree on the selection" do
      endpoints = [
        ep(:loopback, "http://127.0.0.1:4000", scope: :same_host),
        ep(:lan, "http://box.lan", scope: :same_lan)
      ]

      ctx = %{same_host?: true, same_lan?: true, has_session?: true}
      {selected, _dropped} = Broker.select_with_reasons(endpoints, ctx)
      assert selected == Broker.select(endpoints, ctx)
    end
  end

  describe "stickiness — the hysteresis that prevents flapping" do
    setup do
      endpoints = [
        ep(:loopback, "http://127.0.0.1:4000", scope: :same_host),
        ep(:public_https, "https://public.example", auth: :bearer)
      ]

      ctx = %{same_host?: true, has_session?: true, has_bearer?: true}
      %{endpoints: endpoints, ctx: ctx}
    end

    test "a working incumbent wins even against a more-preferred door", %{
      endpoints: endpoints,
      ctx: ctx
    } do
      incumbent = Enum.find(endpoints, &(&1.kind == :public_https))

      [first | _] =
        Broker.select(endpoints, Map.merge(ctx, %{incumbent: incumbent, incumbent_failures: 0}))

      assert first.kind == :public_https,
             "loopback is preferred, but switching away from a working door is the flap"
    end

    test "one failure is not enough to switch", %{endpoints: endpoints, ctx: ctx} do
      incumbent = Enum.find(endpoints, &(&1.kind == :public_https))

      [first | _] =
        Broker.select(endpoints, Map.merge(ctx, %{incumbent: incumbent, incumbent_failures: 1}))

      assert first.kind == :public_https
      refute Broker.switch?(1)
    end

    test "the incumbent is abandoned only after the threshold", %{
      endpoints: endpoints,
      ctx: ctx
    } do
      incumbent = Enum.find(endpoints, &(&1.kind == :public_https))
      threshold = Broker.switch_after_failures()

      assert Broker.switch?(threshold)

      [first | _] =
        Broker.select(
          endpoints,
          Map.merge(ctx, %{incumbent: incumbent, incumbent_failures: threshold})
        )

      assert first.kind == :loopback
    end

    test "the incumbent appears exactly once, not duplicated", %{
      endpoints: endpoints,
      ctx: ctx
    } do
      incumbent = Enum.find(endpoints, &(&1.kind == :public_https))

      selected =
        Broker.select(endpoints, Map.merge(ctx, %{incumbent: incumbent, incumbent_failures: 0}))

      assert length(selected) == length(Enum.uniq_by(selected, & &1.base_url))
    end

    test "an incumbent that is no longer eligible is dropped, not pinned", %{ctx: ctx} do
      only_public = [ep(:public_https, "https://public.example", auth: :bearer)]
      gone = ep(:tailscale, "http://box.tailnet", scope: :same_tailnet)

      selected =
        Broker.select(
          only_public,
          Map.merge(ctx, %{incumbent: gone, incumbent_failures: 0, on_tailnet?: false})
        )

      assert Enum.map(selected, & &1.kind) == [:public_https]
    end
  end
end
