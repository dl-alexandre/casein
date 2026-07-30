defmodule CaseinWeb.FlashJournal do
  @moduledoc """
  Records error flash messages into the durable notification inbox.

  There are ~120 `put_flash(socket, :error, ...)` call sites. Every one of them
  was fire-and-forget: a toast, and if the operator was not looking at that
  corner of the screen when it fired, the failure was gone for good. The bell
  drawer said "Notifications" while the actual stream of things that went wrong
  lived nowhere. This closes that gap without touching a single call site.

  ## Why an `:after_render` hook

  Flash lives in `socket.assigns.flash`, set from anywhere — `handle_event`,
  `handle_info`, `mount`, a `LiveComponent` via `{:panel_flash, ...}`. There is
  no seam that sees all of them *except* the render itself, so this attaches one
  `:after_render` hook per LiveView and diffs the flash map against what it last
  recorded (kept in `socket.private`, so recording never marks assigns changed
  and never triggers another render).

  ## Two deliberate constraints

    * **Off the render path.** The insert runs under `Casein.TaskSupervisor`, not
      inline. A synchronous `Repo` call in a render is both latency in the hot
      path and, if it raised, a crashed LiveView — the same shape as the inline
      HTTP call that caused the PreviewPanes broadcast cascade.

    * **`in_app` only.** A UI error is worth finding later; it is never worth
      waking a phone. These rows carry `default_delivery` that pins them to the
      inbox, so no preference can escalate them to push.
  """

  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, put_private: 3]

  require Logger

  alias Casein.Notifications
  alias CaseinWeb.Plugs.ForwardAuth

  @private_key :casein_flash_journal
  @hook_name :casein_flash_journal

  # Flash kinds worth keeping. `:info` is confirmation of something the operator
  # just did on purpose — durable storage would be pure noise.
  @recorded_kinds ~w(error)

  @type_name "ui_error"
  @dedupe_window_seconds 300
  @ttl_seconds 604_800

  @doc """
  `on_mount` hook: attach the recorder to connected mounts.

  Skipped on the disconnected mount so a dead render (or a crawler) never writes
  a row, and so a reconnect does not re-file an error the operator already saw.
  """
  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) do
      {:cont, attach_hook(socket, @hook_name, :after_render, &record/1)}
    else
      {:cont, socket}
    end
  end

  defp record(socket) do
    current = recordable_flash(socket)
    seen = socket.private[@private_key] || %{}

    current
    |> Enum.reject(fn {kind, message} -> Map.get(seen, kind) == message end)
    |> Enum.each(&deliver(&1, socket))

    # Always track the *current* flash, including its absence. Storing only on a
    # write would pin the last message forever, so once FlashBridge cleared the
    # flash the identical error could never be recorded again.
    if current == seen, do: socket, else: put_private(socket, @private_key, current)
  end

  defp recordable_flash(socket) do
    flash = socket.assigns[:flash] || %{}

    @recorded_kinds
    |> Enum.flat_map(fn kind ->
      case Map.get(flash, kind) do
        message when is_binary(message) ->
          case String.trim(message) do
            "" -> []
            trimmed -> [{kind, trimmed}]
          end

        _ ->
          []
      end
    end)
    |> Map.new()
  end

  defp deliver({kind, message}, socket) do
    attrs = attrs_for(kind, message, socket)

    Task.Supervisor.start_child(Casein.TaskSupervisor, fn ->
      case Notifications.deliver(attrs, dedupe_window_seconds: @dedupe_window_seconds) do
        {:ok, _notification, _status} ->
          :ok

        {:error, changeset} ->
          Logger.warning("flash journal rejected an entry: #{inspect(changeset.errors)}")
      end
    end)
  end

  defp attrs_for(kind, message, socket) do
    user_id = ForwardAuth.viewer_id(socket.assigns[:current_user])
    workspace_id = workspace_id(socket)

    %{
      user_id: user_id,
      workspace_id: workspace_id,
      type: @type_name,
      severity: "error",
      title: truncate(message, 240),
      metadata: %{
        "surface" => "flash",
        "flash_kind" => kind,
        "view" => inspect(socket.view)
      },
      # Group repeats of the same failure instead of stacking one row per click.
      dedupe_key: "flash:#{kind}:#{fingerprint(message)}",
      ttl_seconds: @ttl_seconds,
      deep_link: workspace_id && "/workspaces/#{URI.encode_www_form(workspace_id)}",
      channels: ["in_app"],
      default_delivery: %{
        "in_app" => true,
        "push" => false,
        "browser" => false,
        "mobile" => false,
        "digest" => false
      },
      source_type: "flash"
    }
  end

  defp workspace_id(socket) do
    case socket.assigns[:workspace] do
      %{id: id} when is_binary(id) -> id
      _ -> nil
    end
  end

  # Hash rather than the raw message: dedupe_key is capped at 512 bytes and a
  # flash body can carry a long path or error string.
  defp fingerprint(message) do
    :crypto.hash(:sha256, message) |> Base.encode16(case: :lower) |> binary_part(0, 32)
  end

  defp truncate(message, max) do
    if String.length(message) > max,
      do: String.slice(message, 0, max - 1) <> "…",
      else: message
  end
end
