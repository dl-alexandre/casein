defmodule DevIDE.Loops.Generator.Anthropic do
  @moduledoc """
  `DevIDE.Loops.Generator` backed by the Anthropic Messages API — the concrete
  "generate" seam that makes the loop autonomous.

  Given the failing target, the accumulated feedback, and the prior diff, it
  reads the test and the code under it from the worktree, asks Claude for a
  minimal `lib/`-only unified diff, and returns it. It deliberately does NOT run
  tests or grade itself — the deterministic `DevIDE.Loops.Sandbox` measures the
  result, so the model cannot game the metric.

  Config (`config :dev_ide, DevIDE.Loops, ...`):

    * `:anthropic_api_key` — overrides `ANTHROPIC_API_KEY` from the environment
    * `:anthropic_model` — defaults to `"claude-opus-4-8"`
    * `:anthropic_req_options` — extra `Req` options (merged last; tests inject a
      `:plug` here to stub the HTTP call)

  Uses adaptive thinking at `effort: high` (the current recommendation for
  coding work). No SDK exists for Elixir, so this calls `/v1/messages` directly
  via `Req`.
  """
  @behaviour DevIDE.Loops.Generator

  @endpoint "https://api.anthropic.com/v1/messages"
  @default_model "claude-opus-4-8"
  @version "2023-06-01"

  @system """
  You are fixing ONE failing Elixir/Phoenix test by editing application code.

  Output ONLY a unified git diff that applies cleanly with `git apply` from the
  repository root. No prose, no explanation, no markdown code fences.

  Rules (these are scored — violating them fails the attempt):
    * Edit ONLY files under lib/. NEVER modify anything under test/.
    * Fix the actual defect. Do not hardcode the expected value, weaken or delete
      assertions, or add a bare `rescue`/`catch` that swallows errors.
    * Keep the diff minimal — change only what the fix requires.
  """

  @impl true
  def generate(ctx) do
    with {:ok, key} <- api_key() do
      body = request_body(ctx)

      case post(key, body) do
        {:ok, %{status: 200, body: resp}} ->
          {:ok, %{diff: extract_text(resp), notes: stop_note(resp)}}

        {:ok, %{status: status, body: resp}} ->
          {:error, {:anthropic_http, status, truncate(inspect(resp))}}

        {:error, reason} ->
          {:error, {:anthropic_request_failed, reason}}
      end
    end
  end

  defp request_body(ctx) do
    %{
      model: model(),
      max_tokens: 16_000,
      thinking: %{type: "adaptive"},
      output_config: %{effort: "high"},
      system: @system,
      messages: [%{role: "user", content: user_prompt(ctx)}]
    }
  end

  defp user_prompt(ctx) do
    [
      "Target failing test: #{ctx.target}",
      "Round #{Map.get(ctx, :iteration, 1)}.",
      "",
      source_section("FAILING TEST", target_file(ctx)),
      source_section("CODE UNDER TEST (edit here)", lib_file(ctx)),
      feedback_section(Map.get(ctx, :feedback)),
      prior_section(Map.get(ctx, :prior_diff)),
      "",
      "Return the unified diff that fixes the target test."
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp source_section(_label, nil), do: nil

  defp source_section(label, {path, contents}),
    do: "#{label} (#{path}):\n```\n#{contents}\n```"

  defp feedback_section(fb) when is_binary(fb) and fb != "",
    do: "FEEDBACK FROM LAST ROUND:\n#{fb}"

  defp feedback_section(_), do: nil

  defp prior_section(diff) when is_binary(diff) and diff != "",
    do: "PRIOR ATTEMPT DIFF (build on it or discard it):\n#{String.slice(diff, 0, 4000)}"

  defp prior_section(_), do: nil

  # `test/foo/bar_test.exs:42` -> read the file
  defp target_file(%{root: root, target: target}) when is_binary(root) do
    read(root, target |> to_string() |> String.split(":") |> hd())
  end

  defp target_file(_), do: nil

  # Map a conventional test path to its lib file: test/dev_ide/foo_test.exs -> lib/dev_ide/foo.ex
  defp lib_file(%{root: root, target: target}) when is_binary(root) do
    rel =
      target
      |> to_string()
      |> String.split(":")
      |> hd()
      |> String.replace_prefix("test/", "lib/")
      |> String.replace_suffix("_test.exs", ".ex")

    read(root, rel)
  end

  defp lib_file(_), do: nil

  defp read(root, rel) do
    path = Path.join(root, rel)

    case File.read(path) do
      {:ok, contents} -> {rel, String.slice(contents, 0, 12_000)}
      _ -> nil
    end
  end

  defp post(key, body) do
    options =
      [
        url: @endpoint,
        headers: [{"x-api-key", key}, {"anthropic-version", @version}],
        json: body,
        receive_timeout: 180_000
      ]
      |> Keyword.merge(req_options())

    {:ok, Req.post!(options)}
  rescue
    error -> {:error, error}
  end

  defp extract_text(%{"content" => blocks}) when is_list(blocks) do
    blocks
    |> Enum.filter(&(is_map(&1) and &1["type"] == "text"))
    |> Enum.map_join("", & &1["text"])
    |> strip_fences()
  end

  defp extract_text(_), do: ""

  # The model is told not to fence, but strip them defensively.
  defp strip_fences(text) do
    text
    |> String.trim()
    |> String.replace(~r/^```[a-zA-Z]*\n/, "")
    |> String.replace(~r/\n```$/, "")
    |> String.trim()
  end

  defp stop_note(%{"stop_reason" => reason}) when is_binary(reason), do: "stop_reason=#{reason}"
  defp stop_note(_), do: ""

  defp api_key do
    case config()[:anthropic_api_key] || System.get_env("ANTHROPIC_API_KEY") do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :missing_anthropic_api_key}
    end
  end

  defp model, do: config()[:anthropic_model] || @default_model
  defp req_options, do: config()[:anthropic_req_options] || []
  defp config, do: Application.get_env(:dev_ide, DevIDE.Loops, [])

  defp truncate(string), do: String.slice(string, 0, 500)
end
