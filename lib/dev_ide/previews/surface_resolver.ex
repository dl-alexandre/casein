defmodule DevIDE.Previews.SurfaceResolver do
  @moduledoc """
  Resolves named preview surfaces from workspace metadata.

  v3/devbox workspaces advertise `type`, `domain_base`, and `ports` via the
  manager integration. Surfaces are derived as `https://{service}.{domain_base}`
  so agents and humans share the same preview URLs without scraping terminal
  output.
  """

  alias DevIDE.Previews.Surface
  alias DevIDE.Previews.Url

  @v3_surface_order ~w(app http tidewave api milc-platform-server opencode)
  @port_aliases %{"http" => "app", "milc-platform-server" => "app"}

  @doc """
  Returns named surfaces for a workspace.

  Manager metadata surfaces are returned first (stable ordering), followed by
  any terminal-detected localhost candidates.
  """
  @spec resolve(map()) :: [Surface.t()]
  def resolve(workspace) when is_map(workspace) do
    metadata = metadata(workspace)

    (manager_surfaces(metadata) ++ terminal_surfaces(workspace))
    |> Enum.uniq_by(& &1.url)
    |> Enum.sort_by(&surface_sort_key/1)
  end

  @doc """
  URL safe to load in the user's browser preview panel.

  Loopback surfaces (`app-local`, `localhost:PORT`) only work when the browser
  runs on the devbox. Remote DevIDE sessions use the manager public URL instead
  while agents keep controlling the loopback origin server-side.
  """
  @spec embed_url(map(), Surface.t()) :: String.t()
  def embed_url(workspace, %Surface{} = surface) do
    if Url.localhost_url?(surface.url) do
      case get(workspace, public_surface_name(surface.name)) do
        %Surface{url: public_url} = _public ->
          if Url.localhost_url?(public_url), do: surface.url, else: public_url

        _ ->
          surface.url
      end
    else
      surface.url
    end
  end

  @doc """
  Best surface for agent-first preview control.

  Prefers loopback `app-local` (server-side Playwright/Req), then public `app`,
  then any non-loopback manager surface.
  """
  @spec primary_surface(map()) :: Surface.t() | nil
  def primary_surface(workspace) when is_map(workspace) do
    surfaces = resolve(workspace)

    Enum.find(surfaces, &(&1.name == "app-local")) ||
      Enum.find(surfaces, &(&1.name == "app")) ||
      Enum.find(surfaces, &(not Url.localhost_url?(&1.url))) ||
      List.first(surfaces)
  end

  @doc "Fetch a single surface by name, or nil when unknown."
  @spec get(map(), String.t() | atom()) :: Surface.t() | nil
  def get(workspace, name) when is_map(workspace) do
    name = to_string(name)

    Enum.find(resolve(workspace), fn surface ->
      surface.name == name
    end)
  end

  defp manager_surfaces(metadata) do
    type = metadata_value(metadata, :type)
    domain_base = metadata_value(metadata, :domain_base)
    ports = metadata_value(metadata, :ports) || %{}

    if v3_workspace?(type) and is_binary(domain_base) and domain_base != "" do
      ports
      |> ordered_port_entries()
      |> Enum.map(fn {name, port} ->
        surface_name = Map.get(@port_aliases, name, name)

        %Surface{
          name: surface_name,
          url: surface_url(surface_name, domain_base),
          title: surface_title(surface_name),
          port: port,
          source: :manager
        }
      end)
      |> Enum.concat(localhost_surfaces(ports))
      |> Enum.uniq_by(& &1.url)
    else
      []
    end
  end

  defp terminal_surfaces(workspace) do
    case terminal_output(workspace) do
      output when is_binary(output) and output != "" ->
        DevIDE.Previews.Detector.discover(output)
        |> Enum.map(fn candidate ->
          %Surface{
            name: "localhost:#{candidate.port}",
            url: candidate.url,
            title: candidate.title,
            port: candidate.port,
            source: :terminal
          }
        end)

      _ ->
        []
    end
  end

  defp terminal_output(workspace) do
    Map.get(workspace, :terminal_output) ||
      metadata_value(metadata(workspace), :terminal_output)
  end

  defp ordered_port_entries(ports) when is_map(ports) do
    known =
      @v3_surface_order
      |> Enum.flat_map(fn key ->
        case Map.fetch(ports, key) do
          {:ok, port} when is_integer(port) -> [{key, port}]
          _ -> []
        end
      end)

    extra =
      ports
      |> Enum.reject(fn {key, port} ->
        not is_integer(port) or key in @v3_surface_order or Map.has_key?(@port_aliases, key)
      end)
      |> Enum.sort_by(fn {key, _port} -> key end)

    known
    |> Enum.map(fn {key, port} -> {Map.get(@port_aliases, key, key), port} end)
    |> Enum.uniq_by(fn {name, _port} -> name end)
    |> Kernel.++(extra)
  end

  defp ordered_port_entries(_), do: []

  defp localhost_surfaces(ports) when is_map(ports) do
    Enum.flat_map(["http", "app", "tidewave", "api"], fn key ->
      case Map.get(ports, key) do
        port when is_integer(port) ->
          name = Map.get(@port_aliases, key, key)

          [
            %Surface{
              name: "localhost:#{port}",
              url: "http://127.0.0.1:#{port}",
              title: "localhost:#{port}",
              port: port,
              source: :manager
            },
            %Surface{
              name: "#{name}-local",
              url: "http://localhost:#{port}",
              title: surface_title(name) <> " (local)",
              port: port,
              source: :manager
            }
          ]

        _ ->
          []
      end
    end)
    |> Enum.uniq_by(& &1.url)
  end

  defp localhost_surfaces(_), do: []

  defp surface_url(name, domain_base) do
    host =
      case name do
        "app" -> domain_base
        other -> "#{other}.#{domain_base}"
      end

    "https://#{host}"
  end

  defp surface_title("app"), do: "App"
  defp surface_title("tidewave"), do: "Tidewave"
  defp surface_title("api"), do: "API"
  defp surface_title("milc-platform-server"), do: "Platform"
  defp surface_title("opencode"), do: "OpenCode"
  defp surface_title(name), do: String.capitalize(name)

  defp public_surface_name("app-local"), do: "app"
  defp public_surface_name("localhost:" <> _), do: "app"
  defp public_surface_name(name), do: String.replace(name, "-local", "")

  defp surface_sort_key(%Surface{url: url, name: name}) do
    {if(Url.localhost_url?(url), do: 1, else: 0), name}
  end

  defp v3_workspace?(:v3), do: true
  defp v3_workspace?("v3"), do: true
  defp v3_workspace?(_), do: false

  defp metadata(%{metadata: metadata}) when is_map(metadata), do: metadata
  defp metadata(workspace) when is_map(workspace), do: workspace

  defp metadata_value(metadata, key) when is_map(metadata) and is_atom(key) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp metadata_value(_, _), do: nil
end
