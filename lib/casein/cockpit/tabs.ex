defmodule Casein.Cockpit.Tabs do
  @moduledoc """
  The cockpit's addressable view surfaces — the single definition of the tab set.

  This list was previously restated verbatim in three places: the cockpit's own
  `switch_tab` / `?tab=` gate (`CaseinWeb.WorkspaceLive.Show`), the palette
  catalog that generates the "Open tab: …" items
  (`Casein.CommandPalette.Actions`), and the mobile resume-card locator
  validator (`Casein.Mobile.ResumeCard`). Copies can disagree, and the failure
  is quiet in the worse direction: a tab one surface accepts but the cockpit's
  gate rejects produces a no-op selection rather than an error.

  It lives in the domain rather than the web tier because two of the three
  consumers are domain modules, and the domain may not depend on `CaseinWeb`.

  ## On the two kinds of tab

  These nine are not nine of the same thing:

    * **In the workspace** — `terminal`, `files`, `artifacts` have a spatial
      position and belong in the pane grid (see `Casein.Panes.Pane`).
    * **About the workspace** — `search`, `diff`, `run`, `proposals`, `logs`,
      `history` are inspectors. They describe workspace state rather than
      occupying it, and today they take over the whole main area, so consulting
      one costs sight of the terminal that produced it.

  The list is deliberately flat: nothing consumes the split yet, and encoding it
  before there is a dock to consume it would be a shape without a user.
  """

  @tabs ~w(terminal files search diff artifacts run proposals logs history)

  @doc "Every addressable cockpit tab, in presentation order."
  @spec all() :: [String.t()]
  def all, do: @tabs

  @doc "Whether `tab` names a real cockpit surface."
  @spec valid?(term()) :: boolean()
  def valid?(tab), do: tab in @tabs
end
