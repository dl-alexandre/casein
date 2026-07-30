defmodule Casein.Workspaces.Reconciler.Plan do
  @moduledoc """
  Pure decision core for `Casein.Workspaces.Reconciler`.

  Given an authoritative workspace listing, the listing's scope, and the
  persisted records, decides which records the manager has stopped vouching
  for. No HTTP, no processes, no clock — every guard below is directly
  testable, which is the point: the failure mode of getting this wrong is
  retiring live workspaces belonging to other people.

  A record is retired only if it clears *every* guard:

    * the listing was fetched successfully and is non-empty — a manager
      outage returning `[]` must never read as "everything was deleted";
    * the record's `external_id` is absent from the listing;
    * the record is owned by a user the listing actually covered (see
      `Casein.WorkspaceSource.Manager.listing_scope/1`) — a listing scoped to
      one user says nothing about anyone else's workspaces;
    * the record is not synthetic — scratch and folder-attach workspaces are
      IDE-local constructs that no manager listing will ever contain;
    * the record has not been seen within the grace window, so a single
      partial listing cannot retire anything on its own;
    * the record's `host_path` directory is **gone from disk** — see below.

  Everything else is reported as a skip with its reason, so a sweep can log
  precisely why it did nothing.

  ## Why disk corroboration is not optional

  "Absent from the manager listing" turned out to be too weak a signal on the
  real box: a dry-run found 453 persisted records against a manager listing of
  81, and 84 of the would-be-retired records were *live directories still on
  disk* (real workspaces the manager simply does not track — host-stage and
  pre-Manager-era ones). Retiring those would hide working workspaces.

  A genuine manager deletion removes the git worktree (milc-devbox
  `workspace.remove` → `git.removeWorktree`), so the true deletion signature is
  *absent from the listing* **and** *directory gone*. The disk check is the
  second half of that AND. It can only ever add a skip, never a new retirement,
  so it is strictly safer than listing-absence alone.

  A record whose `host_path` is blank cannot be corroborated either way, so it
  is skipped as `:unverifiable` rather than guessed at.
  """

  alias Casein.Workspace
  alias Casein.Workspaces.State.WorkspaceRecord

  @scratch_id "__scratch__"
  @folder_prefix "folder:"

  @type scope :: :global | {:user, String.t()}
  @typedoc "Answers whether a record's `host_path` still points at a live directory."
  @type dir_present_fun :: (String.t() -> boolean())
  @type skip_reason ::
          :present
          | :synthetic
          | :already_retired
          | :out_of_scope
          | :within_grace
          | :unverifiable
          | :on_disk
  @type t :: %__MODULE__{
          retire: [WorkspaceRecord.t()],
          skipped: %{skip_reason() => non_neg_integer()},
          scope: scope(),
          listed: non_neg_integer()
        }

  defstruct retire: [], skipped: %{}, scope: :global, listed: 0

  @doc """
  Builds the retirement plan.

  Options:
    * `:now` (required) — reference time for the grace window.
    * `:grace_ms` (required) — how long a record must have gone unseen.
    * `:scope` (required) — what the listing covers.
    * `:host_path_present?` (required) — `(host_path -> boolean())`, the disk
      corroboration. The reconciler passes `File.dir?/1`; tests pass a stub.
      Only called for records that clear every cheaper guard, so the IO stays
      proportional to the number of genuine deletion candidates.
  """
  @spec build([Workspace.t()], [WorkspaceRecord.t()], keyword()) :: t()
  def build(listed, records, opts) when is_list(listed) and is_list(records) do
    now = Keyword.fetch!(opts, :now)
    grace_ms = Keyword.fetch!(opts, :grace_ms)
    scope = Keyword.fetch!(opts, :scope)
    dir_present? = Keyword.fetch!(opts, :host_path_present?)

    present_ids = MapSet.new(listed, & &1.id)
    cutoff = DateTime.add(now, -grace_ms, :millisecond)

    {retire, skipped} =
      Enum.reduce(records, {[], %{}}, fn record, {retire, skipped} ->
        case classify(record, present_ids, scope, cutoff, dir_present?) do
          :retire -> {[record | retire], skipped}
          reason -> {retire, Map.update(skipped, reason, 1, &(&1 + 1))}
        end
      end)

    %__MODULE__{
      retire: Enum.reverse(retire),
      skipped: skipped,
      scope: scope,
      listed: length(listed)
    }
  end

  defp classify(%WorkspaceRecord{} = record, present_ids, scope, cutoff, dir_present?) do
    cond do
      MapSet.member?(present_ids, record.external_id) -> :present
      synthetic?(record.external_id) -> :synthetic
      WorkspaceRecord.retired?(record) -> :already_retired
      not in_scope?(record, scope) -> :out_of_scope
      not unseen_since?(record, cutoff) -> :within_grace
      not verifiable_host_path?(record) -> :unverifiable
      dir_present?.(record.host_path) -> :on_disk
      true -> :retire
    end
  end

  # No host_path, no corroboration: a manager deletion is defined by the
  # worktree being gone, and we cannot check a directory we were never told
  # about. Refuse to guess.
  defp verifiable_host_path?(%WorkspaceRecord{host_path: p}), do: is_binary(p) and p != ""

  # Scratch and folder-attach workspaces are minted by Casein itself
  # (`Casein.Workspaces.Scratch`, the `folder:`-encoded attach path). The
  # manager has never heard of them, so their absence carries no information.
  defp synthetic?(@scratch_id), do: true
  defp synthetic?(@folder_prefix <> _rest), do: true
  defp synthetic?(_external_id), do: false

  # A listing scoped to one user is evidence about that user only. Records with
  # no recorded owner are never in scope — they predate owner tracking or come
  # from a source that does not report one, and guessing is not worth a wrongly
  # retired workspace.
  defp in_scope?(_record, :global), do: true
  defp in_scope?(%WorkspaceRecord{user: user}, {:user, user}) when is_binary(user), do: true
  defp in_scope?(_record, {:user, _other}), do: false

  # A record never seen at all cannot be aged out: without a timestamp there is
  # no evidence it was ever in a listing, so the grace window cannot have passed.
  defp unseen_since?(%WorkspaceRecord{last_seen_at: %DateTime{} = at}, cutoff),
    do: DateTime.compare(at, cutoff) == :lt

  defp unseen_since?(_record, _cutoff), do: false
end
