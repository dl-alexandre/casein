defmodule Casein.Access.Broker do
  @moduledoc """
  Chooses which advertised door a client should use.

  Pure and stateless: `select/2` takes the inventory plus a client context and
  returns an ordered candidate list. The caller owns the state (which endpoint
  is currently working, how many times it has failed in a row) and threads it
  back in. That keeps selection testable and avoids another supervised process
  in a hot path.

  ## Stickiness is load-bearing, not polish

  Two bugs in this codebase were edge-triggered logic oscillating between two
  plausible states: the mobile letterbox (fixed with `latchMobileAuthority`
  hysteresis) and the stranded terminal fit (fixed with a level-triggered
  self-heal). An endpoint broker that re-decides on every probe reproduces that
  class exactly — a phone straddling LAN and cellular would flap between doors
  and tear down a healthy transport each time.

  So: an incumbent that is still reachable always wins, and switching away
  requires `@switch_after_failures` consecutive failures. Ties prefer the
  incumbent.

  ## Scope filtering happens before probing

  `Casein.Access.Endpoint` carries a `scope`. A client that is not on the
  tailnet must never even probe a MagicDNS name, so unreachable-by-scope
  candidates are dropped here rather than discovered by timeout.
  """

  alias Casein.Access.Endpoint

  @switch_after_failures 3

  @preference [:loopback, :lan, :tailscale, :public_https, :ssh_forward]

  @type client_context :: %{
          optional(:same_host?) => boolean(),
          optional(:on_tailnet?) => boolean(),
          optional(:same_lan?) => boolean(),
          optional(:has_session?) => boolean(),
          optional(:has_bearer?) => boolean(),
          optional(:incumbent) => Endpoint.t() | nil,
          optional(:incumbent_failures) => non_neg_integer()
        }

  @doc """
  Ordered endpoints this client should try, best first.

  Drops candidates the client cannot reach by `scope` or satisfy by `auth`,
  then orders by `@preference`. When an incumbent is supplied and has not yet
  failed `#{@switch_after_failures}` consecutive times, it is placed first
  regardless of preference — see the stickiness note in the moduledoc.
  """
  @spec select([Endpoint.t()], client_context()) :: [Endpoint.t()]
  def select(endpoints, context \\ %{}) when is_list(endpoints) and is_map(context) do
    {selected, _dropped} = select_with_reasons(endpoints, context)
    selected
  end

  @doc """
  Like `select/2`, but also returns why each candidate was dropped.

  Scope filtering is **strict**: an absent `same_host?` / `on_tailnet?` /
  `same_lan?` flag reads as `false`, because guessing "probably reachable" is how
  a phone off the tailnet ends up timing out against a MagicDNS name. The
  consequence is that `select(advertised(), %{})` legitimately returns `[]` —
  every advertised door is scoped, and an empty context claims to be nowhere.

  That empty result is correct but easy to misread as "nothing is advertised", so
  this function exists to make it diagnosable. Use it when a client reports no
  reachable endpoints:

      {[], dropped} = Broker.select_with_reasons(Endpoints.advertised(), %{})
      # dropped => [{%Endpoint{kind: :loopback}, {:scope_not_satisfied, :same_host}}]
  """
  @spec select_with_reasons([Endpoint.t()], client_context()) ::
          {[Endpoint.t()], [{Endpoint.t(), term()}]}
  def select_with_reasons(endpoints, context \\ %{})
      when is_list(endpoints) and is_map(context) do
    incumbent = Map.get(context, :incumbent)
    failures = Map.get(context, :incumbent_failures, 0)

    {eligible, dropped} =
      Enum.reduce(endpoints, {[], []}, fn endpoint, {keep, drop} ->
        case eligibility(endpoint, context) do
          :ok -> {[endpoint | keep], drop}
          {:error, reason} -> {keep, [{endpoint, reason} | drop]}
        end
      end)

    eligible =
      eligible
      |> Enum.reverse()
      |> Enum.sort_by(&preference_index/1)

    selected =
      case sticky_incumbent(incumbent, failures, eligible) do
        nil -> eligible
        pinned -> [pinned | Enum.reject(eligible, &same_endpoint?(&1, pinned))]
      end

    {selected, Enum.reverse(dropped)}
  end

  defp eligibility(%Endpoint{} = endpoint, context) do
    cond do
      not reachable_scope?(endpoint, context) ->
        {:error, {:scope_not_satisfied, endpoint.scope}}

      not satisfiable_auth?(endpoint, context) ->
        {:error, {:auth_not_held, endpoint.auth}}

      true ->
        :ok
    end
  end

  @doc """
  True when the incumbent should be abandoned.

  Only after `#{@switch_after_failures}` consecutive failures. A single failed
  probe is not enough — that is the hysteresis.
  """
  @spec switch?(non_neg_integer()) :: boolean()
  def switch?(consecutive_failures) when is_integer(consecutive_failures),
    do: consecutive_failures >= @switch_after_failures

  @doc "Consecutive failures required before switching away from a working door."
  @spec switch_after_failures() :: pos_integer()
  def switch_after_failures, do: @switch_after_failures

  defp sticky_incumbent(nil, _failures, _eligible), do: nil

  defp sticky_incumbent(%Endpoint{} = incumbent, failures, eligible) do
    if switch?(failures) do
      nil
    else
      Enum.find(eligible, &same_endpoint?(&1, incumbent))
    end
  end

  defp same_endpoint?(%Endpoint{base_url: a}, %Endpoint{base_url: b}), do: a == b

  defp preference_index(%Endpoint{kind: kind}) do
    case Enum.find_index(@preference, &(&1 == kind)) do
      nil -> length(@preference)
      index -> index
    end
  end

  # Scope says who can even reach this door. Unknown scopes are permissive so a
  # new endpoint kind is not silently dropped.
  defp reachable_scope?(%Endpoint{scope: :any}, _context), do: true
  defp reachable_scope?(%Endpoint{scope: :same_host}, ctx), do: flag(ctx, :same_host?)
  defp reachable_scope?(%Endpoint{scope: :same_tailnet}, ctx), do: flag(ctx, :on_tailnet?)
  defp reachable_scope?(%Endpoint{scope: :same_lan}, ctx), do: flag(ctx, :same_lan?)
  defp reachable_scope?(%Endpoint{}, _context), do: true

  # Auth says whether this client holds what the door demands. Absent context
  # keys are permissive: callers that do not model credentials still get an
  # ordered list rather than an empty one.
  defp satisfiable_auth?(%Endpoint{auth: :session}, ctx), do: optional_flag(ctx, :has_session?)
  defp satisfiable_auth?(%Endpoint{auth: :bearer}, ctx), do: optional_flag(ctx, :has_bearer?)
  defp satisfiable_auth?(%Endpoint{}, _context), do: true

  defp flag(ctx, key), do: Map.get(ctx, key, false) == true

  defp optional_flag(ctx, key) do
    case Map.fetch(ctx, key) do
      {:ok, value} -> value == true
      :error -> true
    end
  end
end
