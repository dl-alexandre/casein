defmodule Mix.Tasks.DevIde.Preview.Demo do
  @shortdoc "Live demo of preview control against a v3 workspace"
  @moduledoc """
  Demonstrates the agent-first preview loop against a real or manager-fetched
  v3 workspace.

      mix dev_ide.preview.demo
      mix dev_ide.preview.demo dalexandre-twenty-one
      mix dev_ide.preview.demo --surface app-local
  """

  use Mix.Task

  @requirements ["app.start"]

  def run(args) do
    Mix.Task.run("ecto.migrate")

    {opts, rest, _} = OptionParser.parse(args, strict: [surface: :string, adapter: :string])
    surface = opts[:surface] || "app-local"
    adapter = parse_adapter(opts[:adapter])

    workspace =
      case rest do
        [name] -> fetch_workspace!(name)
        _ -> fetch_workspace!("dalexandre-twenty-one")
      end

    run_demo(workspace, surface, adapter)
  end

  defp run_demo(workspace, surface, adapter) do
    Mix.shell().info("\n=== DevIDE Preview Control Demo ===\n")
    Mix.shell().info("Workspace: #{workspace.name} (#{workspace.id})")
    Mix.shell().info("Adapter: #{adapter}")

    Mix.shell().info("\n--- Surfaces ---")

    for s <- DevIDE.Previews.discover_surfaces(workspace) do
      Mix.shell().info("  #{String.pad_trailing(s.name, 18)} #{s.url}")
    end

    case DevIDE.Previews.SurfaceResolver.get(workspace, surface) do
      nil ->
        Mix.raise("Surface #{surface} not found. Try: app, app-local, localhost:10405")

      %{} = chosen ->
        Mix.shell().info("\n--- Opening #{chosen.name} @ #{chosen.url} ---")

        with {:ok, session} <-
               DevIDE.PreviewControl.open_session(workspace, chosen.name,
                 actor_id: "preview-demo",
                 adapter: adapter
               ),
             {:ok, observation} <- DevIDE.PreviewControl.observe(session.id),
             {:ok, click_obs} <-
               DevIDE.PreviewControl.click(session.id, %{selector: "a.login-btn"}),
             {:ok, screenshot} <- DevIDE.PreviewControl.screenshot(session.id) do
          Mix.shell().info("  session_id: #{session.id}")
          Mix.shell().info("  url:        #{observation[:url]}")
          Mix.shell().info("  title:      #{observation[:title] || "(no title)"}")

          if summary = observation[:dom_summary] do
            headings = Map.get(summary, :headings) || Map.get(summary, "headings") || []
            Mix.shell().info("  headings:   #{inspect(Enum.take(headings, 3))}")

            Mix.shell().info(
              "  body bytes: #{Map.get(summary, :byte_size) || Map.get(summary, "byte_size")}"
            )
          end

          Mix.shell().info("  after click url:   #{obs_field(click_obs, :url)}")
          Mix.shell().info("  after click title: #{obs_field(click_obs, :title) || "(no title)"}")
          Mix.shell().info("  screenshot: #{screenshot[:artifact_path] || "(simulated)"}")

          import Ecto.Query
          alias DevIde.Repo

          actions =
            Repo.all(
              from a in DevIDE.Previews.ControlAction,
                where: a.session_id == ^session.id,
                order_by: [asc: a.inserted_at],
                select: a.action
            )

          Mix.shell().info("  audit:      #{inspect(actions)}")
          DevIDE.PreviewControl.close_session(session.id)
          Mix.shell().info("\n✓ Demo complete\n")
          System.stop()
        else
          {:error, reason} -> Mix.raise("Demo failed: #{inspect(reason)}")
        end
    end
  end

  defp fetch_workspace!(name) do
    auth = System.get_env("DEV_IDE_DEMO_AUTH_EMAIL", "dalexandre@milcgroup.com")

    case DevIDE.Integrations.Manager.Client.list([], auth) do
      {:ok, list} ->
        case Enum.find(list, &(&1.name == name)) do
          nil -> Mix.raise("Workspace #{name} not found in manager")
          ws -> to_workspace(ws)
        end

      {:error, reason} ->
        Mix.raise("Manager unavailable: #{inspect(reason)}")
    end
  end

  defp to_workspace(%DevIDE.Integrations.Manager.Workspace{} = ws) do
    %DevIDE.Workspace{
      id: ws.id,
      name: ws.name,
      user: ws.user,
      branch: ws.branch,
      status: ws.status,
      path: ws.path,
      metadata: %{
        type: ws.type,
        slot: ws.slot,
        domain_base: ws.domain_base,
        ports: ws.ports,
        raw: ws.raw
      }
    }
  end

  defp obs_field(obs, key) when is_map(obs) do
    Map.get(obs, key) || Map.get(obs, Atom.to_string(key))
  end

  defp parse_adapter(nil), do: :playwright
  defp parse_adapter("memory"), do: :memory
  defp parse_adapter("playwright"), do: :playwright
  defp parse_adapter(other), do: String.to_existing_atom(other)
end
