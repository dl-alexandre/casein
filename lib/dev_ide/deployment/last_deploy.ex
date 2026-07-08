defmodule DevIDE.Deployment.LastDeploy do
  @moduledoc """
  Reads the on-box deploy poller status file (`/run/devide/last-deploy.json`).

  The poller writes this file on every deploy attempt so the running release can
  distinguish "origin/master advanced, deploy in flight" from "deploy of SHA X
  failed: gate red" — cases that otherwise look identical via drift alone.
  """

  require Logger

  alias DevIDE.Deployment.{Drift, Version}

  @default_path "/run/devide/last-deploy.json"
  @stale_in_progress_ms 2_700_000
  @phase_stale_in_progress_ms %{"activate" => 600_000}

  @type outcome :: :idle | :in_progress | :failed | :success | :unknown
  @type banner_info :: %{
          outcome: String.t(),
          target_sha: String.t() | nil,
          target_short: String.t() | nil,
          from_sha: String.t() | nil,
          phase: String.t() | nil,
          reason: String.t() | nil,
          message: String.t(),
          started_at: String.t() | nil,
          finished_at: String.t() | nil
        }

  @doc "Returns the configured status file path."
  @spec path() :: String.t()
  def path, do: config(:last_deploy_path, @default_path)

  @doc "Reads and decodes the poller status file."
  @spec read(keyword()) :: {:ok, map()} | {:error, :missing | :invalid}
  # Path comes from application config (:deployment :last_deploy_path), not user input.
  # sobelow_skip ["Traversal.FileModule"]
  def read(opts \\ []) do
    file_path = Keyword.get(opts, :path, path())

    case File.read(file_path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{} = record} -> {:ok, record}
          _ -> {:error, :invalid}
        end

      {:error, :enoent} ->
        {:error, :missing}

      {:error, _} ->
        {:error, :missing}
    end
  end

  @doc """
  Pure assessment of a poller record against the running revision and remote head.

  Returns `:idle` when the record is absent, stale, or not actionable; `{:in_progress, info}`
  while a deploy is actively running; `{:failed, info}` when the poller aborted; `:success`
  when the record documents a completed handoff to the running revision.
  """
  @spec assess(String.t() | nil, {:ok, String.t()} | {:error, term()}, map() | nil) ::
          :idle | :success | {:in_progress, banner_info()} | {:failed, banner_info()}
  def assess(deployed, {:ok, remote_sha}, record) when is_map(record) do
    deployed = normalize(deployed)
    remote_sha = normalize(remote_sha)
    target = normalize(record["target_sha"])
    outcome = record["outcome"]

    cond do
      outcome == "in_progress" and actionable_target?(target, deployed, remote_sha) and
          not stale_in_progress?(record) ->
        {:in_progress, banner_info(record)}

      outcome == "failed" and actionable_target?(target, deployed, remote_sha) ->
        {:failed, banner_info(record)}

      outcome == "success" and sha_matches?(target, deployed) ->
        :success

      true ->
        :idle
    end
  end

  def assess(_deployed, _remote, _record), do: :idle

  @doc "Returns the banner-oriented status for the running instance."
  @spec banner_status(keyword()) ::
          :idle | {:in_progress, banner_info()} | {:failed, banner_info()}
  def banner_status(opts \\ []) do
    deployed = Keyword.get_lazy(opts, :deployed, &Version.version/0)
    branch = Keyword.get(opts, :branch) || Drift.branch()

    remote =
      case Keyword.fetch(opts, :remote_head) do
        {:ok, remote_head} -> remote_head
        :error -> Drift.remote_head(branch: branch)
      end

    case read(opts) do
      {:ok, record} ->
        case assess(deployed, remote, record) do
          {:in_progress, _} = status -> status
          {:failed, _} = status -> status
          _ -> :idle
        end

      _ ->
        :idle
    end
  end

  @doc "Starts a best-effort async poller-status check unless disabled by env."
  @spec check_async() :: :ok
  def check_async do
    if System.get_env("DEV_IDE_DEPLOY_POLLER_WATCH") in ["0", "false", "no"] do
      :ok
    else
      _ = Task.start(fn -> check_and_broadcast() end)
      :ok
    end
  end

  @doc "Reads the status file and broadcasts banner updates when actionable."
  @spec check_and_broadcast(keyword()) :: outcome()
  def check_and_broadcast(opts \\ []) do
    case banner_status(opts) do
      {:in_progress, info} ->
        Logger.info("DevIDE deploy poller in progress", target: info.target_short)
        broadcast({:deploy_in_progress, info})
        :in_progress

      {:failed, info} ->
        Logger.warning("DevIDE deploy poller failed",
          reason: info.reason,
          target: info.target_short
        )

        broadcast({:deploy_failure, info})
        :failed

      :idle ->
        broadcast(:deploy_poller_clear)
        :idle
    end
  end

  @doc "Builds a compact summary for health/API payloads."
  @spec summary(keyword()) :: map()
  def summary(opts \\ []) do
    deployed = Keyword.get_lazy(opts, :deployed, &Version.version/0)
    branch = Keyword.get(opts, :branch) || Drift.branch()

    remote =
      case Keyword.fetch(opts, :remote_head) do
        {:ok, remote_head} -> remote_head
        :error -> Drift.remote_head(branch: branch)
      end

    case read(opts) do
      {:ok, record} ->
        pipeline = pipeline_status(deployed, remote, record)

        %{
          record: record,
          pipeline: pipeline,
          actionable: pipeline in [:in_progress, :failed]
        }

      {:error, reason} ->
        %{record: nil, pipeline: :unknown, actionable: false, read_error: reason}
    end
  end

  defp pipeline_status(deployed, remote, record) do
    case assess(deployed, remote, record) do
      {:in_progress, _} -> :in_progress
      {:failed, _} -> :failed
      :success -> :ok
      :idle -> :idle
    end
  end

  defp banner_info(record) do
    %{
      outcome: record["outcome"],
      target_sha: record["target_sha"],
      target_short: record["target_short"] || short_sha(record["target_sha"]),
      from_sha: record["from_sha"],
      phase: record["phase"],
      reason: record["reason"],
      message: human_message(record),
      started_at: record["started_at"],
      finished_at: record["finished_at"]
    }
  end

  defp human_message(%{"outcome" => "in_progress", "phase" => "gate"} = record),
    do: progress_message(record, "Running pre-push gate")

  defp human_message(%{"outcome" => "in_progress", "phase" => "build"} = record),
    do: progress_message(record, "Building release")

  defp human_message(%{"outcome" => "in_progress", "phase" => "activate"} = record),
    do: progress_message(record, "Activating release")

  defp human_message(%{"outcome" => "in_progress", "phase" => phase} = record)
       when is_binary(phase) and phase != "",
       do: progress_message(record, "Deploy #{phase}")

  defp human_message(%{"outcome" => "failed", "phase" => "gate", "reason" => reason})
       when is_binary(reason) and reason != "",
       do: "Deploy failed at pre-push gate: #{reason}"

  defp human_message(%{"outcome" => "failed", "phase" => "gate"}),
    do: "Deploy failed: pre-push gate red"

  defp human_message(%{"outcome" => "failed", "phase" => phase, "reason" => reason})
       when is_binary(phase) and is_binary(reason) and reason != "",
       do: "Deploy failed during #{phase}: #{reason}"

  defp human_message(%{"outcome" => "failed", "reason" => reason})
       when is_binary(reason) and reason != "",
       do: "Deploy failed: #{reason}"

  defp human_message(%{"outcome" => "failed"}), do: "Deploy failed"

  defp human_message(%{"outcome" => "in_progress"} = record),
    do: progress_message(record, "Deploying")

  defp human_message(_), do: "Deploy status updated"

  defp progress_message(record, label) do
    [label, target_fragment(record), elapsed_fragment(record)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
    |> Kernel.<>("…")
  end

  defp target_fragment(%{"target_short" => short}) when is_binary(short) and short != "",
    do: short

  defp target_fragment(%{"target_sha" => sha}) when is_binary(sha) and sha != "",
    do: short_sha(sha)

  defp target_fragment(_), do: nil

  defp elapsed_fragment(%{"started_at" => started_at}) when is_binary(started_at) do
    with {:ok, dt, _} <- DateTime.from_iso8601(started_at),
         seconds when seconds >= 60 <- DateTime.diff(DateTime.utc_now(), dt, :second) do
      "#{div(seconds, 60)}m"
    else
      _ -> nil
    end
  end

  defp elapsed_fragment(_), do: nil

  defp actionable_target?(target, deployed, remote_sha) do
    is_binary(target) and target != "" and not sha_matches?(target, deployed) and
      sha_matches?(target, remote_sha)
  end

  defp stale_in_progress?(%{"started_at" => started_at} = record) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, dt, _} ->
        DateTime.diff(DateTime.utc_now(), dt, :millisecond) > stale_in_progress_ms(record)

      _ ->
        false
    end
  end

  defp stale_in_progress?(_), do: false

  defp stale_in_progress_ms(%{"phase" => phase}) when is_binary(phase) do
    :dev_ide
    |> Application.get_env(:deployment, [])
    |> Keyword.get(:phase_stale_in_progress_ms, @phase_stale_in_progress_ms)
    |> Map.get(phase, stale_in_progress_ms())
  end

  defp stale_in_progress_ms(_record), do: stale_in_progress_ms()

  defp stale_in_progress_ms do
    config(:stale_in_progress_ms, @stale_in_progress_ms)
  end

  defp short_sha(nil), do: nil
  defp short_sha(sha) when is_binary(sha), do: String.slice(sha, 0, 12)

  defp sha_matches?(left, right) when is_binary(left) and is_binary(right) do
    left == right or String.starts_with?(right, left) or String.starts_with?(left, right)
  end

  defp sha_matches?(_, _), do: false

  defp normalize(nil), do: nil

  defp normalize(value) do
    value
    |> to_string()
    |> String.trim()
    |> then(fn trimmed ->
      if trimmed == "", do: nil, else: trimmed
    end)
  end

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(DevIde.PubSub, "deploy:updates", message)
  rescue
    _ -> :ok
  end

  defp config(key, default) do
    :dev_ide
    |> Application.get_env(:deployment, [])
    |> Keyword.get(key, default)
  end
end
