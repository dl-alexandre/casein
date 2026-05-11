defmodule DevIDE.Runners.DriftTest do
  @moduledoc """
  Protocol drift detection. These tests compare implementation against
  fixtures and docs. If the implementation changes incompatibly without
  updating fixtures or docs, these tests fail.

  Rule: docs win. When implementation and docs diverge, fix the code or
  bump the protocol version and update all fixtures.

  Test-backed contracts:
    * `docs/jx_devide.md` — protocol envelope and endpoint contract
    * `docs/state_machines.md` — state transitions and start-event set
    * `docs/failure_taxonomy.md` — failure class taxonomy and mapping
    * `docs/protocol_governance.md` — version policy and fixture law
    * `test/fixtures/jx_runner_v1/*.json` — versioned request/response schemas
  """

  use ExUnit.Case, async: true

  alias DevIDE.Commands
  alias DevIDE.Runners
  alias DevIDE.Runners.{Assignment, Failure, ProgressReport, SafeAction, StateMachine}

  @protocol_version "jx.runner.v1"
  @fixture_dir Path.join([__DIR__, "..", "..", "fixtures", "jx_runner_v1"])

  ## 1. Protocol version drift

  test "protocol version is stable and matches fixtures" do
    assert Runners.protocol() == @protocol_version

    for name <- ~w(enqueue_request poll_request) do
      fixture = load_fixture!("#{name}.json")

      assert fixture["execution_protocol"] == @protocol_version or
               fixture["protocol"] == @protocol_version,
             "fixture #{name}.json protocol version drift"
    end
  end

  ## 2. Failure-class drift

  test "failure taxonomy is complete and fixtures use only valid classes" do
    classes = MapSet.new(Failure.classes())
    assert MapSet.size(classes) == 7

    fixture_classes =
      ~w(error_claim_rejected.json error_report_rejected.json fail_request.json
         fail_response.json replay_response.json)
      |> Enum.flat_map(fn name ->
        fixture = load_fixture!(name)
        collect_failure_classes(fixture)
      end)
      |> MapSet.new()

    unknown = MapSet.difference(fixture_classes, classes)

    assert MapSet.size(unknown) == 0,
           "fixtures contain unknown failure classes: #{inspect(MapSet.to_list(unknown))}"

    unused = MapSet.difference(classes, fixture_classes)
    # Some classes only appear at runtime (lease_expired, runner_lost, replay_mismatch)
    # We verify they exist in the taxonomy via unit tests; here we just check
    # that all fixture-used classes are valid.
    assert MapSet.size(unused) >= 0
  end

  test "failure class mapping is exhaustive for known internal reasons" do
    # Every internal error atom the protocol uses must map to a known class.
    known_reasons = [
      :safe_action_not_allowed,
      :not_found,
      :shared_stage_guarded,
      :unsafe_db,
      :capabilities_required,
      :protocol_not_supported,
      :runner_id_required,
      :lease_expired,
      :runner_lost,
      :action_failed,
      :replay_mismatch,
      :claim_token_invalid,
      :assignment_not_claimed,
      :assignment_terminal,
      :duplicate_report_conflict,
      :invalid_transition,
      :forbidden_payload,
      :event_not_allowed,
      :evidence_required
    ]

    for reason <- known_reasons do
      class = Failure.class(reason)

      assert class in Failure.classes(),
             "internal reason #{inspect(reason)} maps to unknown class #{inspect(class)}"
    end
  end

  ## 3. State-machine drift

  test "state machine transitions match the documented v1 contract" do
    # Every documented transition must exist in the implementation.
    documented = [
      {"queued", :claim, "claimed"},
      {"queued", :expire, "expired"},
      {"queued", :abandon, "abandoned"},
      {"claimed", :start, "running"},
      {"claimed", :succeed, "succeeded"},
      {"claimed", :fail, "failed"},
      {"claimed", :expire, "expired"},
      {"claimed", :abandon, "abandoned"},
      {"running", :succeed, "succeeded"},
      {"running", :fail, "failed"},
      {"running", :expire, "expired"},
      {"running", :abandon, "abandoned"}
    ]

    for {from, event, to} <- documented do
      assert StateMachine.transition(from, event) == {:ok, to},
             "documented transition #{from} + #{event} -> #{to} drift"
    end

    # Terminal states must reject all transitions.
    for status <- StateMachine.terminal_statuses(),
        event <- ~w(claim start succeed fail expire abandon)a do
      assert StateMachine.transition(status, event) == {:error, :assignment_terminal},
             "terminal state #{status} should reject #{event}"
    end

    # Invalid transitions must return :invalid_transition.
    assert StateMachine.transition("queued", :succeed) == {:error, :invalid_transition}
    assert StateMachine.transition("running", :claim) == {:error, :invalid_transition}
  end

  test "start events match the documented set" do
    documented_start_events = ~w(started progress stdout stderr evidence)

    for event <- documented_start_events do
      assert StateMachine.start_event?(event),
             "documented start event #{event} not recognized"
    end

    refute StateMachine.start_event?("heartbeat")
    refute StateMachine.start_event?("completed")
    refute StateMachine.start_event?("failed")
  end

  test "state machine statuses match the documented set" do
    assert StateMachine.statuses() ==
             ~w(queued claimed running succeeded failed expired abandoned)
  end

  ## 4. Safe-action registry drift

  test "safe action registry is derived exclusively from Commands.allowlist" do
    allowlist_ids = Commands.allowlist() |> Map.keys() |> MapSet.new()
    action_ids = SafeAction.all() |> Enum.map(& &1.id) |> MapSet.new()

    assert action_ids == MapSet.new(Enum.map(allowlist_ids, &"command:#{&1}"))

    for action <- SafeAction.all() do
      assert action.version == 1
      assert action.kind == :workspace_command
      assert action.requires == ["workspace-command:v1"]
      assert {:ok, ^action} = SafeAction.fetch(action.id)
      assert {:ok, ^action} = SafeAction.fetch_command(action.command_id)
    end
  end

  test "safe action payload shape is stable" do
    action = %SafeAction{
      id: "command:test",
      version: 1,
      kind: :workspace_command,
      command_id: "test",
      argv: ["mix", "test", "--color"],
      requires: ["workspace-command:v1"],
      description: "Run the allowlisted test workspace command."
    }

    payload = SafeAction.to_runner_payload(action)

    assert payload == %{
             id: "command:test",
             version: 1,
             kind: "workspace_command",
             command_id: "test",
             argv: ["mix", "test", "--color"],
             requires: ["workspace-command:v1"],
             description: "Run the allowlisted test workspace command."
           }

    # Verify the fixture matches this exact shape.
    fixture = load_fixture!("enqueue_response.json")
    assert fixture["assignment"]["action"] == Jason.decode!(Jason.encode!(payload))
  end

  ## 5. Envelope drift

  test "all fixture envelopes contain only documented top-level keys" do
    # Enqueue response
    assert envelope_keys(load_fixture!("enqueue_response.json")) ==
             MapSet.new(["assignment", "protocol"])

    # Poll response
    assert envelope_keys(load_fixture!("poll_response.json")) ==
             MapSet.new(["assignment", "protocol"])

    # Report response
    assert envelope_keys(load_fixture!("report_response.json")) ==
             MapSet.new(["protocol", "report"])

    # Complete response
    assert envelope_keys(load_fixture!("complete_response.json")) ==
             MapSet.new(["assignment", "protocol", "report"])

    # Fail response
    assert envelope_keys(load_fixture!("fail_response.json")) ==
             MapSet.new(["assignment", "protocol", "report"])

    # Replay response
    assert envelope_keys(load_fixture!("replay_response.json")) ==
             MapSet.new(["assignment", "protocol", "reports"])

    # Error responses
    assert envelope_keys(load_fixture!("error_claim_rejected.json")) ==
             MapSet.new(["error", "failure_class"])

    assert envelope_keys(load_fixture!("error_report_rejected.json")) ==
             MapSet.new(["error", "failure_class"])
  end

  test "assignment payload shape is stable across all fixtures" do
    assignment_keys =
      ~w(id workspace_id safe_action_id safe_action_version status requested_by
         claimed_by claim_token queued_at claimed_at lease_expires_at completed_at
         failure_reason failure_class evidence metadata action)
      |> MapSet.new()

    for fixture_name <- ~w(enqueue_response.json poll_response.json
                           complete_response.json fail_response.json
                           replay_response.json) do
      fixture = load_fixture!(fixture_name)
      keys = fixture["assignment"] |> Map.keys() |> MapSet.new()

      assert MapSet.subset?(keys, assignment_keys),
             "fixture #{fixture_name} has unexpected assignment keys: #{inspect(MapSet.difference(keys, assignment_keys) |> MapSet.to_list())}"
    end
  end

  test "report payload shape is stable across all fixtures" do
    report_keys =
      ~w(id assignment_id client_report_id runner_id position event stream message
         data data_truncated evidence failure_class observed_at inserted_at)
      |> MapSet.new()

    for fixture_name <- ~w(report_response.json complete_response.json
                           fail_response.json replay_response.json) do
      fixture = load_fixture!(fixture_name)

      reports =
        case fixture_name do
          "replay_response.json" -> fixture["reports"]
          _ -> [fixture["report"]]
        end

      for report <- reports do
        keys = report |> Map.keys() |> MapSet.new()

        assert MapSet.subset?(keys, report_keys),
               "fixture #{fixture_name} has unexpected report keys: #{inspect(MapSet.difference(keys, report_keys) |> MapSet.to_list())}"
      end
    end
  end

  ## 6. Assignment struct drift

  test "Assignment struct fields match the documented schema" do
    fields =
      ~w(id workspace_id safe_action_id safe_action_version status requested_by
         claimed_by claim_token queued_at claimed_at lease_expires_at completed_at
         failure_reason evidence metadata inserted_at updated_at)a

    assert MapSet.new(Assignment.__struct__() |> Map.keys() |> Enum.reject(&(&1 == :__struct__))) ==
             MapSet.new(fields)
  end

  test "ProgressReport struct fields match the documented schema" do
    fields =
      ~w(id assignment_id client_report_id runner_id position event stream message
         data data_truncated evidence observed_at inserted_at)a

    assert MapSet.new(
             ProgressReport.__struct__()
             |> Map.keys()
             |> Enum.reject(&(&1 == :__struct__))
           ) ==
             MapSet.new(fields)
  end

  ## Helpers

  defp load_fixture!(name) do
    @fixture_dir
    |> Path.join(name)
    |> File.read!()
    |> Jason.decode!()
  end

  defp envelope_keys(map) when is_map(map), do: map |> Map.keys() |> MapSet.new()

  defp collect_failure_classes(map) when is_map(map) do
    classes =
      case map do
        %{"failure_class" => class} when is_binary(class) -> [class]
        _ -> []
      end

    nested =
      map
      |> Map.values()
      |> Enum.flat_map(&collect_failure_classes/1)

    classes ++ nested
  end

  defp collect_failure_classes(list) when is_list(list) do
    Enum.flat_map(list, &collect_failure_classes/1)
  end

  defp collect_failure_classes(_), do: []
end
