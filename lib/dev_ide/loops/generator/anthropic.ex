defmodule DevIDE.Loops.Generator.Anthropic do
  @moduledoc """
  `DevIDE.Loops.Generator` backed by the Anthropic Messages API.

  Asks `claude-opus-4-8` (adaptive thinking, `effort: high`) for a minimal
  `lib/`-only unified diff that fixes the target test. Prompt construction and
  fence-stripping are shared via `DevIDE.Loops.Generator.Prompt`. No Elixir SDK
  exists, so this calls `/v1/messages` directly via `Req`.

  Needs an API key. If the box has an authenticated `claude` CLI instead, prefer
  `DevIDE.Loops.Generator.ClaudeCli` (no key required).

  Config (`config :dev_ide, DevIDE.Loops, ...`):

    * `:anthropic_api_key` — overrides `ANTHROPIC_API_KEY` from the environment
    * `:anthropic_model` — defaults to `"claude-opus-4-8"`
    * `:anthropic_req_options` — extra `Req` options (tests inject a `:plug` stub)
  """
  @behaviour DevIDE.Loops.Generator

  alias DevIDE.Loops.Generator.Prompt

  @endpoint "https://api.anthropic.com/v1/messages"
  @default_model "claude-opus-4-8"
  @version "2023-06-01"

  @impl true
  def generate(ctx) do
    with {:ok, key} <- api_key() do
      case post(key, request_body(ctx)) do
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
      system: Prompt.system_prompt(),
      messages: [%{role: "user", content: Prompt.user_prompt(ctx)}]
    }
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
    |> Prompt.strip_fences()
  end

  defp extract_text(_), do: ""

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
