defmodule Casein.Agents.PreviewTools.SetCookies do
  @moduledoc "preview_set_cookies."

  use Jido.Action,
    name: "preview_set_cookies",
    description:
      "Inject cookies into the preview browser context. Cookie values are never returned or audited.",
    category: "preview",
    tags: ["preview", "mutation"],
    vsn: "1.0.0",
    schema: [
      session_id: [type: {:or, [:integer, :string]}, required: true],
      cookies: [type: {:list, {:map, :any, :any}}, required: true]
    ]

  @behaviour Casein.Agents.ToolAction

  alias Casein.Agents.PreviewTools.{Helpers, Impl}
  alias McpCtl.Tool

  @impl Casein.Agents.ToolAction
  def parameters do
    Tool.object(
      %{
        session_id: %{type: "string", description: "Preview control session id."},
        cookies: %{
          type: "array",
          items:
            Tool.object(
              %{
                name: %{type: "string"},
                value: %{type: "string"},
                url: %{type: "string"},
                domain: %{type: "string"},
                path: %{type: "string"},
                secure: %{type: "boolean"},
                httpOnly: %{type: "boolean"},
                sameSite: %{type: "string", enum: ["Strict", "Lax", "None"]}
              },
              [:name, :value]
            ),
          description: "Playwright-compatible cookies; url defaults to the current origin."
        }
      },
      [:session_id, :cookies]
    )
  end

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("preview_set_cookies")

  @impl Jido.Action
  def run(params, _context), do: Impl.set_cookies(Helpers.to_impl_args(params))
end
