defmodule Casein.Terminals.TmuxEvents do
  @moduledoc """
  Casein facade for the host-tmux control-mode event source.

  Flag-gated by `config :casein, :tmux_events` (env `DEVIDE_TMUX_EVENTS`).
  When off, `child_spec/1` starts as `:ignore` and `subscribe/2` returns
  `{:error, :unavailable}` so watchers stay on pure polling.
  """

  @behaviour TmuxCtl.EventSource

  alias Casein.Terminals.TmuxServer
  alias TmuxCtl.Events.ControlListener

  @topic_prefix "tmux_events:"
  @listener_name __MODULE__.Listener

  @doc "Whether the event-driven tmux path is enabled."
  @spec enabled?() :: boolean()
  def enabled? do
    case Application.get_env(:casein, :tmux_events, false) do
      true -> true
      "1" -> true
      "true" -> true
      _ -> false
    end
  end

  @doc "Host tmux server label (`-L`), or nil when using the default server."
  @spec host_label() :: String.t() | nil
  def host_label, do: TmuxServer.label()

  @doc "PubSub topic for a server label."
  @spec topic(String.t()) :: String.t()
  def topic(label) when is_binary(label), do: @topic_prefix <> label

  @doc "Registered name of the supervised control listener (when running)."
  @spec listener_name() :: atom()
  def listener_name, do: @listener_name

  @impl TmuxCtl.EventSource
  def subscribe(_arg, _subscriber) do
    label = host_label()

    cond do
      not enabled?() ->
        {:error, :unavailable}

      not is_binary(label) or label == "" ->
        {:error, :unavailable}

      true ->
        case Process.whereis(@listener_name) do
          nil ->
            {:error, :unavailable}

          pid when is_pid(pid) ->
            pubsub = pubsub()
            # Idempotent: retry loops re-subscribe during listener outages, and
            # duplicate subscriptions would fan every lifecycle broadcast out
            # K times to the same watcher.
            :ok = Phoenix.PubSub.unsubscribe(pubsub, topic(label))
            :ok = Phoenix.PubSub.subscribe(pubsub, topic(label))

            connected? =
              case ControlListener.status(pid) do
                %{state: :connected} -> true
                _ -> false
              end

            {:ok, %{listener: pid, connected?: connected?}}
        end
    end
  end

  @doc false
  def child_spec(opts \\ []) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  @doc false
  def start_link(opts \\ []) do
    if enabled?() and is_binary(host_label()) do
      ControlListener.start_link(
        Keyword.merge(
          [
            label: host_label(),
            pubsub: pubsub(),
            anchor_session:
              Application.get_env(
                :casein,
                :tmux_events_anchor_session,
                "__devide_keepalive"
              ),
            name: @listener_name
          ],
          opts
        )
      )
    else
      :ignore
    end
  end

  defp pubsub do
    Application.get_env(:tmux_ctl, :pubsub) ||
      Application.get_env(:casein, :pubsub, Casein.PubSub)
  end
end
