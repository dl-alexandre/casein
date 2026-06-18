defmodule DevIDE.Previews.Commands do
  @moduledoc """
  Preview commands for terminals and agents.

  Provides a narrow, audited surface to discover workspace previews, open
  control sessions, observe pages, and interact — without arbitrary URLs.
  """

  alias DevIDE.Agents.PreviewTools
  alias DevIDE.PreviewControl
  alias DevIDE.Previews

  @type result :: %{
          status: String.t(),
          line: String.t(),
          argv: [String.t()],
          exit_code: non_neg_integer() | term(),
          output: String.t(),
          output_truncated: boolean()
        }

  @doc "Preview command examples surfaced in command help."
  def examples do
    [
      "preview surfaces",
      "preview open app-local",
      "preview observe 1",
      "preview screenshot 1"
    ]
  end

  @spec run(map(), String.t(), [String.t()], keyword()) :: {:ok, result()} | {:error, term()}
  def run(workspace, line, argv, opts \\ []) when is_map(workspace) and is_list(argv) do
    actor_id = Keyword.get(opts, :actor_id, "terminal")

    case argv do
      ["preview"] ->
        help(line)

      ["preview", "surfaces"] ->
        surfaces(workspace, line)

      ["preview", "open", surface] ->
        open(workspace, surface, line, actor_id)

      ["preview", "observe", session_id] ->
        observe(session_id, line)

      ["preview", "screenshot", session_id] ->
        screenshot(session_id, line)

      ["preview", "click", session_id, selector] ->
        click(session_id, selector, line)

      ["preview", "navigate", session_id, path] ->
        navigate(session_id, path, line)

      ["preview", "close", session_id] ->
        close(session_id, line)

      ["preview", "errors", session_id] ->
        errors(workspace, session_id, line)

      _ ->
        {:error, :not_allowed}
    end
  end

  defp help(line) do
    output =
      [
        "Preview control commands:",
        "",
        "  preview surfaces              List manager + localhost surfaces",
        "  preview open <surface>        Open control session (e.g. app, app-local)",
        "  preview observe <session_id>  Observe current page",
        "  preview screenshot <id>       Capture screenshot artifact",
        "  preview click <id> <selector> Click element by CSS selector",
        "  preview navigate <id> <path>  Navigate within allowed origin",
        "  preview errors <id>           Report console/network errors",
        "  preview close <id>            Close control session"
      ]
      |> Enum.join("\n")

    ok(line, ["preview"], output)
  end

  defp surfaces(workspace, line) do
    lines =
      workspace
      |> Previews.discover_surfaces()
      |> Enum.map(fn s -> "  #{String.pad_trailing(s.name, 18)} #{s.url}" end)

    output =
      ["Surfaces:" | lines]
      |> Enum.join("\n")

    ok(line, ["preview", "surfaces"], output)
  end

  defp open(workspace, surface, line, actor_id) do
    case PreviewControl.open_session(workspace, surface,
           actor_id: actor_id,
           adapter: configured_adapter()
         ) do
      {:ok, session} ->
        {:ok, observation} = PreviewControl.observe(session.id)

        output =
          [
            "Opened preview control session",
            "  session_id: #{session.id}",
            "  surface:    #{session.surface}",
            "  url:        #{session.current_url}",
            "  title:      #{observation[:title] || "(no title)"}",
            "",
            "Next: preview observe #{session.id}"
          ]
          |> Enum.join("\n")

        ok(line, ["preview", "open", surface], output)

      {:error, :surface_not_found} ->
        ok(line, ["preview", "open", surface], "Surface not found: #{surface}\n", 1)

      {:error, reason} ->
        ok(line, ["preview", "open", surface], "Failed: #{inspect(reason)}\n", 1)
    end
  end

  defp observe(session_id, line) do
    with {:ok, id} <- parse_id(session_id),
         {:ok, observation} <- PreviewControl.observe(id) do
      ok(line, ["preview", "observe", session_id], format_observation(observation))
    else
      {:error, reason} ->
        ok(line, ["preview", "observe", session_id], "Failed: #{inspect(reason)}\n", 1)
    end
  end

  defp screenshot(session_id, line) do
    with {:ok, id} <- parse_id(session_id),
         {:ok, shot} <- PreviewControl.screenshot(id) do
      artifact = shot[:artifact_path] || shot["artifact_path"] || "(none)"

      ok(
        line,
        ["preview", "screenshot", session_id],
        "Screenshot captured\n  artifact: #{artifact}\n  url: #{shot[:url]}\n"
      )
    else
      {:error, reason} ->
        ok(line, ["preview", "screenshot", session_id], "Failed: #{inspect(reason)}\n", 1)
    end
  end

  defp click(session_id, selector, line) do
    with {:ok, id} <- parse_id(session_id),
         {:ok, obs} <- PreviewControl.click(id, %{selector: selector}) do
      ok(line, ["preview", "click", session_id, selector], format_observation(obs))
    else
      {:error, reason} ->
        ok(line, ["preview", "click", session_id, selector], "Failed: #{inspect(reason)}\n", 1)
    end
  end

  defp navigate(session_id, path, line) do
    with {:ok, id} <- parse_id(session_id),
         {:ok, obs} <- PreviewControl.navigate(id, path) do
      ok(line, ["preview", "navigate", session_id, path], format_observation(obs))
    else
      {:error, reason} ->
        ok(line, ["preview", "navigate", session_id, path], "Failed: #{inspect(reason)}\n", 1)
    end
  end

  defp close(session_id, line) do
    with {:ok, id} <- parse_id(session_id),
         {:ok, _} <- PreviewControl.close_session(id) do
      ok(line, ["preview", "close", session_id], "Session #{session_id} closed\n")
    else
      {:error, reason} ->
        ok(line, ["preview", "close", session_id], "Failed: #{inspect(reason)}\n", 1)
    end
  end

  defp errors(workspace, session_id, line) do
    with {:ok, id} <- parse_id(session_id),
         {:ok, payload} <-
           PreviewTools.invoke("preview_report_errors", workspace, %{"session_id" => id}) do
      ok(line, ["preview", "errors", session_id], inspect(payload) <> "\n")
    else
      {:error, reason} ->
        ok(line, ["preview", "errors", session_id], "Failed: #{inspect(reason)}\n", 1)
    end
  end

  defp format_observation(obs) when is_map(obs) do
    summary = obs[:dom_summary] || obs["dom_summary"] || %{}
    headings = Map.get(summary, :headings) || Map.get(summary, "headings") || []

    [
      "url:   #{obs[:url] || obs["url"]}",
      "title: #{obs[:title] || obs["title"] || "(no title)"}",
      "headings: #{inspect(Enum.take(headings, 5))}",
      "console_errors: #{inspect(obs[:console_errors] || obs["console_errors"] || [])}"
    ]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> {:ok, n}
      _ -> {:error, :invalid_session_id}
    end
  end

  defp configured_adapter do
    Application.get_env(:dev_ide, :preview_control_adapter, :memory)
  end

  defp ok(line, argv, output, exit_code \\ 0) do
    {:ok,
     %{
       status: if(exit_code == 0, do: "completed", else: "failed"),
       line: line,
       argv: argv,
       exit_code: exit_code,
       output: output,
       output_truncated: false
     }}
  end
end
