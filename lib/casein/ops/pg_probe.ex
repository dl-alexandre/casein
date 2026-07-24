defmodule Casein.Ops.PgProbe do
  @moduledoc """
  Periodic Postgres connection-saturation probe for the box's servers.

  Known incident shapes this exists to catch: leaked `wf_*` BEAM nodes
  exhausting the host Postgres on 5432, and leaked `devide-<uuid>` canary
  connections exhausting the release Postgres on 15432 until deploys
  crash-loop. Both manifest as `pg_stat_activity` filling with leak-shaped
  `application_name`s long before anyone notices.

  Off by default; flag `:pg_probe` (`CASEIN_PG_PROBE`). Every
  `:pg_probe_interval_ms` (60s) a monitored helper process shells out to
  `psql` per target (`System.cmd` — no new hex deps) for
  `SELECT application_name, count(*) FROM pg_stat_activity GROUP BY 1` plus
  `SHOW max_connections`. Targets default to both known servers and are
  configurable as JSON via `CASEIN_PG_PROBE_TARGETS`
  (`[{"host":"127.0.0.1","port":5432}, ...]`, optional per-target
  `user`/`dbname`/`password`); credentials default to the dev-conventional
  postgres/postgres and are configurable via `CASEIN_PG_PROBE_USER` /
  `CASEIN_PG_PROBE_DBNAME` / `CASEIN_PG_PROBE_PASSWORD`.

  Per target the probe computes total connections, `max_connections`,
  utilization, and leak_suspects (application_name matching `^wf_` or
  `^devide-<uuid>`). An unreachable or auth-failed target yields a
  `%{status: :unreachable}` sample — that is itself signal, not a crash; a
  "too many clients" refusal is the saturation incident in its terminal
  form and escalates straight to `:critical`.

  Threshold transitions (warn at `:pg_probe_warn_utilization` 0.7, critical
  at `:pg_probe_critical_utilization` 0.9, or any leak-suspect total above
  `:pg_probe_leak_suspects_max` 10) follow the `operator.risk_*` pattern:
  transitions only, an `ops.pg_saturation_raised` / `ops.pg_saturation_cleared`
  audit row first (box-global — the `"_ops"` sentinel workspace, like
  `Casein.Deployment.DeployAudit`'s `"_deploy"`), then a
  `{:ops_health, :pg_saturation, :raised | :cleared, risk}` broadcast on the
  box-global `"ops:health"` topic. `Casein.Operator.SituationServer`
  subscribes and folds the risks into every workspace digest.
  """

  use GenServer
  require Logger

  alias Casein.Audit
  alias Casein.Export.Sanitizer

  @pubsub Casein.PubSub
  @topic "ops:health"

  # Box-global rows: audit_events.workspace_id is NOT NULL, so ops events use
  # a sentinel workspace id (the DeployAudit "_deploy" pattern).
  @workspace_id "_ops"

  @default_targets [
    %{host: "127.0.0.1", port: 5432},
    %{host: "127.0.0.1", port: 15_432}
  ]

  # Leak-shaped application_names: wf_* workflow BEAMs and devide-<uuid>
  # canary connections (the two known saturation incidents).
  @leak_patterns [~r/^wf_/, ~r/^devide-[0-9a-f]{8}-[0-9a-f-]+$/]

  @activity_query "SELECT application_name, count(*) FROM pg_stat_activity GROUP BY 1"

  # Unit separator — psql -F field separator that no application_name uses.
  @field_sep <<0x1F>>

  # How many leak-suspect names ride along in evidence/audit metadata.
  @evidence_suspects 5

  defstruct samples: [], active: %{}, probe_ref: nil, probe_pid: nil

  ## Public API

  @doc "Whether the probe is enabled (`CASEIN_PG_PROBE`)."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:casein, :pg_probe, false)

  @doc "Whether a probe server is running (started by the supervision tree)."
  @spec running?() :: boolean()
  def running?, do: Process.whereis(__MODULE__) != nil

  @doc """
  The latest per-target samples, whereis-safe: `[]` when no probe is running
  (or before the first pass lands). Feeds the digest's `ops.pg` section.
  """
  @spec current() :: [map()]
  def current do
    case Process.whereis(__MODULE__) do
      nil -> []
      pid -> GenServer.call(pid, :current, 5_000)
    end
  catch
    :exit, _ -> []
  end

  @doc "Active pg_saturation risks, whereis-safe: `[]` when no probe runs."
  @spec active_risks() :: [map()]
  def active_risks do
    case Process.whereis(__MODULE__) do
      nil -> []
      pid -> GenServer.call(pid, :active_risks, 5_000)
    end
  catch
    :exit, _ -> []
  end

  @doc "Box-global PubSub topic carrying `{:ops_health, :pg_saturation, kind, risk}`."
  @spec topic() :: String.t()
  def topic, do: @topic

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, @topic)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  ## GenServer

  @impl true
  def init(_opts) do
    # First pass right away so the digest's ops section and any already-raised
    # saturation surface without waiting a full interval.
    send(self(), :probe)
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call(:current, _from, state), do: {:reply, state.samples, state}

  def handle_call(:active_risks, _from, state), do: {:reply, Map.values(state.active), state}

  @impl true
  def handle_info(:probe, state) do
    Process.send_after(self(), :probe, interval_ms())
    {:noreply, maybe_start_probe(state)}
  end

  def handle_info({:pg_samples, samples}, state) when is_list(samples) do
    {:noreply, apply_samples(state, samples)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{probe_ref: ref} = state) do
    if reason != :normal do
      Logger.warning("[pg_probe] probe pass failed: #{inspect(reason)}")
    end

    {:noreply, %{state | probe_ref: nil, probe_pid: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # psql shells out with a connect timeout — too slow (and too fallible) for
  # the server loop, so each pass runs in a monitored helper process. A pass
  # still in flight when the next tick fires has outlived a full interval —
  # per-target connect/statement timeouts cap a healthy pass far below it —
  # so it is wedged (e.g. psql blocked on a blackholed connection): kill it
  # instead of silently skipping every future pass. The :DOWN clears the ref
  # and the following tick probes again.
  defp maybe_start_probe(%{probe_ref: ref} = state) when ref != nil do
    Process.exit(state.probe_pid, :kill)
    state
  end

  defp maybe_start_probe(state) do
    parent = self()

    case targets() do
      # Nothing to probe (tests configure this to drive passes by hand) —
      # don't spawn a helper just to report an empty pass.
      [] ->
        state

      targets ->
        {pid, ref} =
          spawn_monitor(fn ->
            send(parent, {:pg_samples, probe_targets(targets)})
          end)

        %{state | probe_ref: ref, probe_pid: pid}
    end
  end

  ## Transitions

  defp apply_samples(state, samples) do
    next_active =
      for sample <- samples,
          risk = evaluate(sample),
          risk != nil,
          into: %{} do
        {{risk.id, risk.subject}, risk}
      end

    for {key, risk} <- next_active, not Map.has_key?(state.active, key) do
      announce(:raised, risk)
    end

    for {key, risk} <- state.active, not Map.has_key?(next_active, key) do
      announce(:cleared, risk)
    end

    %{state | samples: samples, active: next_active}
  end

  # Transition-only fan-out, audit row before broadcast (subscribers reacting
  # to the message can rely on the row existing) — the operator.risk_* dance.
  defp announce(kind, risk) do
    _ =
      Audit.emit!(%{
        workspace_id: @workspace_id,
        actor_id: "pg_probe",
        action: "ops.pg_saturation_#{kind}",
        source: "ops",
        target_type: "postgres",
        target_ref: risk.subject,
        metadata: Map.put(risk.evidence, :severity, risk.severity)
      })

    Phoenix.PubSub.broadcast(@pubsub, @topic, {:ops_health, :pg_saturation, kind, risk})

    :ok
  end

  ## Sample evaluation (pure — unit-testable with fabricated samples)

  @doc """
  Evaluate one sample against the thresholds: `nil` when healthy, otherwise a
  `Casein.Operator.Risks.risk/0`-shaped map with the breach reasons in
  evidence.
  """
  @spec evaluate(map()) :: map() | nil
  def evaluate(sample) when is_map(sample) do
    case breach(sample) do
      nil -> nil
      {severity, reasons} -> risk(sample, severity, reasons)
    end
  end

  defp breach(%{status: :unreachable} = sample) do
    # An exhausted server refuses new connections — the incident's terminal
    # form. Any other unreachable target stays sample-only signal.
    if Map.get(sample, :exhausted), do: {:critical, [:exhausted]}, else: nil
  end

  defp breach(sample) do
    utilization = Map.get(sample, :utilization)
    leak_count = Map.get(sample, :leak_suspect_count, 0)

    cond do
      is_number(utilization) and utilization >= critical_utilization() ->
        {:critical, [:utilization_critical]}

      is_number(utilization) and utilization >= warn_utilization() ->
        {:warn, [:utilization_warn | leak_reasons(leak_count)]}

      leak_count > leak_suspects_max() ->
        {:warn, [:leak_suspects]}

      true ->
        nil
    end
  end

  defp leak_reasons(leak_count) do
    if leak_count > leak_suspects_max(), do: [:leak_suspects], else: []
  end

  defp risk(sample, severity, reasons) do
    %{
      id: :pg_saturation,
      severity: severity,
      subject: subject(sample),
      detected_at: Map.get(sample, :checked_at),
      evidence:
        compact(%{
          reasons: reasons,
          total: Map.get(sample, :total),
          max_connections: Map.get(sample, :max_connections),
          utilization: Map.get(sample, :utilization),
          leak_suspect_count: Map.get(sample, :leak_suspect_count),
          leak_suspects: Enum.take(Map.get(sample, :leak_suspects) || [], @evidence_suspects),
          error: Map.get(sample, :error)
        }),
      suggestion:
        "Postgres #{subject(sample)} is saturating. Find and kill leaked wf_* / " <>
          "devide-<uuid> connections (systemd MainPIDs holding them get kill -TERM) " <>
          "before the server refuses connections and deploys crash-loop."
    }
  end

  defp subject(sample), do: "#{Map.get(sample, :host)}:#{Map.get(sample, :port)}"

  ## Probing (shell out to psql; no new deps)

  @doc false
  @spec probe_targets([map()]) :: [map()]
  def probe_targets(targets) when is_list(targets) do
    Enum.map(targets, &probe_target/1)
  end

  @doc false
  # psql is invoked via System.cmd with an argv list (no shell), and every
  # argument comes from operator-provided probe config, not caller input.
  # sobelow_skip ["CI.System"]
  @spec probe_target(map()) :: map()
  def probe_target(target) do
    args = [
      "-h",
      Map.fetch!(target, :host),
      "-p",
      to_string(Map.fetch!(target, :port)),
      "-U",
      Map.get(target, :user) || default_user(),
      "-d",
      Map.get(target, :dbname) || default_dbname(),
      # Never prompt: a password-less failure must return, not hang on a tty.
      "-w",
      "-tA",
      "-F",
      @field_sep,
      "-c",
      @activity_query,
      "-c",
      "SHOW max_connections"
    ]

    env = [
      {"PGPASSWORD", Map.get(target, :password) || default_password()},
      {"PGCONNECT_TIMEOUT", "5"},
      {"PGOPTIONS", "-c statement_timeout=5000"}
    ]

    case System.cmd(psql(), args, env: env, stderr_to_stdout: true) do
      {output, 0} -> build_sample(target, output)
      {output, _status} -> unreachable_sample(target, output)
    end
  rescue
    # Missing psql binary (ErlangError :enoent) or any other spawn failure is
    # an unreachable sample, never a crashed probe pass.
    error -> unreachable_sample(target, Exception.message(error))
  end

  @doc false
  @spec build_sample(map(), String.t()) :: map()
  def build_sample(target, output) do
    case parse_output(output) do
      {:ok, counts, max_connections} ->
        total = counts |> Enum.map(&elem(&1, 1)) |> Enum.sum()
        suspects = leak_suspects(counts)

        %{
          host: Map.fetch!(target, :host),
          port: Map.fetch!(target, :port),
          status: :ok,
          total: total,
          max_connections: max_connections,
          utilization: utilization(total, max_connections),
          leak_suspects: suspects,
          leak_suspect_count: suspects |> Enum.map(& &1.count) |> Enum.sum(),
          checked_at: DateTime.utc_now()
        }

      :error ->
        unreachable_sample(target, output)
    end
  end

  defp unreachable_sample(target, error) do
    error = error |> to_string() |> String.trim() |> String.slice(0, 200)

    %{
      host: Map.fetch!(target, :host),
      port: Map.fetch!(target, :port),
      status: :unreachable,
      error: Sanitizer.redact_text(error),
      exhausted: error =~ "too many clients",
      checked_at: DateTime.utc_now()
    }
  end

  # psql -tA output: one "name<US>count" line per application_name, then the
  # bare SHOW max_connections value from the second -c on its own line.
  @doc false
  @spec parse_output(String.t()) ::
          {:ok, [{String.t(), non_neg_integer()}], pos_integer()} | :error
  def parse_output(output) when is_binary(output) do
    lines =
      output
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    counts =
      for line <- lines,
          [name, count] <- [String.split(line, @field_sep, parts: 2)],
          {n, ""} <- [Integer.parse(count)] do
        {name, n}
      end

    max_connections =
      lines
      |> Enum.reject(&String.contains?(&1, @field_sep))
      |> Enum.flat_map(fn line ->
        case Integer.parse(line) do
          {n, ""} when n > 0 -> [n]
          _ -> []
        end
      end)
      |> List.last()

    if is_integer(max_connections), do: {:ok, counts, max_connections}, else: :error
  end

  defp utilization(_total, max) when max in [nil, 0], do: nil
  defp utilization(total, max), do: Float.round(total / max, 3)

  # Leak suspect names land in audit metadata and the exported digest —
  # redact like every other free-text field.
  defp leak_suspects(counts) do
    for {name, count} <- counts,
        Enum.any?(@leak_patterns, &Regex.match?(&1, name)) do
      %{application_name: Sanitizer.redact_text(name), count: count}
    end
    |> Enum.sort_by(& &1.count, :desc)
  end

  ## Config

  @doc false
  @spec targets() :: [map()]
  def targets do
    case Application.get_env(:casein, :pg_probe_targets) do
      targets when is_list(targets) and targets != [] -> Enum.map(targets, &normalize_target/1)
      [] -> []
      _ -> targets_from_json(Application.get_env(:casein, :pg_probe_targets_json))
    end
  end

  defp targets_from_json(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, targets} when is_list(targets) and targets != [] ->
        Enum.map(targets, &normalize_target/1)

      _ ->
        Logger.warning("[pg_probe] invalid CASEIN_PG_PROBE_TARGETS JSON — using defaults")
        @default_targets
    end
  end

  defp targets_from_json(_json), do: @default_targets

  defp normalize_target(target) when is_map(target) do
    %{
      host: to_string(value(target, :host) || "127.0.0.1"),
      port: port(value(target, :port)),
      user: value(target, :user),
      dbname: value(target, :dbname),
      password: value(target, :password)
    }
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp port(port) when is_integer(port), do: port

  # targets() runs inside handle_info(:probe) — a config typo ("54O2") must
  # fall back to the default port, not crash-loop the probe every interval.
  defp port(port) when is_binary(port) do
    case Integer.parse(port) do
      {n, ""} when n > 0 ->
        n

      _ ->
        Logger.warning("[pg_probe] invalid target port #{inspect(port)} — using 5432")
        5432
    end
  end

  defp port(_port), do: 5432

  defp interval_ms, do: Application.get_env(:casein, :pg_probe_interval_ms, 60_000)
  defp warn_utilization, do: Application.get_env(:casein, :pg_probe_warn_utilization, 0.7)

  defp critical_utilization,
    do: Application.get_env(:casein, :pg_probe_critical_utilization, 0.9)

  defp leak_suspects_max, do: Application.get_env(:casein, :pg_probe_leak_suspects_max, 10)
  defp psql, do: Application.get_env(:casein, :pg_probe_psql, "psql")
  defp default_user, do: Application.get_env(:casein, :pg_probe_user, "postgres")
  defp default_dbname, do: Application.get_env(:casein, :pg_probe_dbname, "postgres")
  defp default_password, do: Application.get_env(:casein, :pg_probe_password, "postgres")

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", []] end)
    |> Map.new()
  end
end
