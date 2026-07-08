defmodule DevIdeWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and so on.

  This can be used in your application as:

      use DevIdeWeb, :controller
      use DevIdeWeb, :html

  The definitions below will be executed for every controller,
  component, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define additional modules and import
  those modules here.
  """

  # Web layer: may call the domain (DevIDE) and infra (DevIde); the domain
  # must never call back into this boundary. Enforced by the :boundary
  # compiler — violations are compile warnings, promoted to errors by
  # `mix precommit`'s --warnings-as-errors.
  use Boundary,
    deps: [DevIDE],
    exports: :all

  def static_paths,
    do:
      ~w(assets fonts images favicon.ico robots.txt site.webmanifest service-worker.js offline.html whitehouse-preview.html)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      use Gettext, backend: DevIdeWeb.Gettext

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      # The :live layout (layouts/live.html.heex) re-renders on connected diffs.
      # Deploy state from DeploymentUpdateHook is surfaced in the notifications
      # bell and drawer on workspace/dashboard headers, not in the layout.
      use Phoenix.LiveView, layout: {DevIdeWeb.Layouts, :live}

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      # Import convenience functions from controllers
      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      # Include general helpers for rendering HTML
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      # Translation
      use Gettext, backend: DevIdeWeb.Gettext

      # HTML escaping functionality
      import Phoenix.HTML
      # Core UI components
      import DevIdeWeb.CoreComponents

      # Common modules used in templates
      alias Phoenix.LiveView.JS
      alias DevIdeWeb.Layouts

      # Routes generation with the ~p sigil
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: DevIdeWeb.Endpoint,
        router: DevIdeWeb.Router,
        statics: DevIdeWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
