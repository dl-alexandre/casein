defmodule DevIdeWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://hexdocs.pm/telemetry_metrics
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      # Add reporters as children of your supervision tree.
      # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("dev_ide.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("dev_ide.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("dev_ide.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("dev_ide.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("dev_ide.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io"),

      # Terminal owner observability (attach/detach, reconnect UX,
      # migration bridge counters for dashboard). Gauges via poller.
      last_value("dev_ide.terminals.owners.active.count"),
      last_value("dev_ide.terminals.attachments.open.count"),
      # :reuse tag values are atoms (:true/:false) to avoid boolean cardinality surprises in some metric stores/dashboards
      counter("dev_ide.terminals.owner.attach.count", tags: [:mode, :reuse, :kind]),
      counter("dev_ide.terminals.owner.detach.count"),
      counter("dev_ide.terminals.owner.started.count"),
      counter("dev_ide.terminals.owner.orphaned_detach.count"),
      # Focused-viewer sizing: count shared-PTY resizes by WHY this size won
      # (:focused = a viewer is driving, :largest_fallback = nobody focused).
      # A :largest_fallback-dominated split after deploy means viewers aren't
      # reporting focus (e.g. stale client JS).
      counter("dev_ide.terminals.owner.size_changed.count", tags: [:reason, :kind]),
      last_value("dev_ide.terminals.owner.size_changed.active_viewers", tags: [:reason]),

      # Operator attention routing: why a quiet-agent transition stayed silent,
      # rendered inline, or requested an OS notification.
      counter("dev_ide.attention.quiet_agent.transition.count",
        tags: [:reaction, :reason, :surface_state, :target_state]
      )
    ]
  end

  defp periodic_measurements do
    # Delegate to the terminal facade so terminal-specific measurements stay
    # owned by the terminal context.
    DevIDE.Terminals.periodic_measurements()
  end
end
