defmodule CaseinWeb.WorkspaceLive.Show.LeaderHelpEvents do
  # Open/close for the leader cheatsheet overlay. Tab cycling stays client-side;
  # only the open flag is server state so the overlay arbiter can govern it.
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias CaseinWeb.WorkspaceLive.Show.Overlay

  def handle_event("leader_help:toggle", _params, socket) do
    if socket.assigns.leader_help_open do
      {:noreply, assign(socket, :leader_help_open, false)}
    else
      {:noreply,
       socket
       |> Overlay.close_others(:leader_help)
       |> assign(:leader_help_open, true)}
    end
  end

  def handle_event("leader_help:close", _params, socket) do
    {:noreply, assign(socket, :leader_help_open, false)}
  end
end
