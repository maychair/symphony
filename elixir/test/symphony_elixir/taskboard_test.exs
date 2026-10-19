defmodule SymphonyElixir.TaskboardTest do
  use SymphonyElixir.TestSupport, runtime: false

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.Taskboard, as: TaskboardSchema
  alias SymphonyElixir.{Execution, RunJournal, TaskWorkflow, WorkRef}
  alias SymphonyElixir.Taskboard

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    Application.put_env(:symphony_elixir, :memory_tracker_issues, issues())

    Application.put_env(:symphony_elixir, :taskboard_memory_details, %{
      "MOCK-1" => %{
        "description" => "Implement the replayed fixture.",
        "comments" => [
          %{
            id: 11,
            author: "meichao",
            body: "Use the replay fixture.",
            system: false,
            engine: false,
            created_at: "2026-10-17T01:00:00Z"
          },
          %{
            id: 12,
            author: "meichao-symphony-engine",
            body: "Review requested.\n<!-- symphony-engine-notice -->",
            system: false,
            engine: true,
            created_at: "2026-10-17T01:01:00Z"
          }
        ],
        "deliveries" => [
          %{
            kind: "mr",
            number: 9,
            title: "Implement replay",
            url: "https://example.invalid/merge_requests/9",
            merged: false,
            merge_status: "mergeable",
            review_state: "pending",
            unresolved_comments: 2,
            unresolved_supported: true
          }
        ],
        "execution" => %{
          phase: "review",
          attempt_count: 2,
          thread_id: "thread-mock",
          events: [%{event: "review_requested", message: "MR published"}]
        }
      }
    })

    mutator = fn event -> send(self(), {:taskboard_mutation, event}) end
    Application.put_env(:symphony_elixir, :taskboard_memory_mutator, mutator)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :taskboard_memory_details)
      Application.delete_env(:symphony_elixir, :taskboard_memory_mutator)
    end)

    {:ok, settings: settings()}
  end

  test "projects Issues into exactly four columns and keeps unverified closure in Human Review", %{
    settings: settings
  } do
    runtime_snapshot = fn ->
      %{
        running: [
          %{
            issue_id: "2",
            identifier: "MOCK-2",
            state: "In Progress",
            session_id: "thread-running",
            turn_count: 3,
            last_message: "Running tests"
          }
        ],
        retrying: [],
        blocked: [
          %{
            issue_id: "4",
            identifier: "MOCK-4",
            state: "In Progress",
            error: "Input required",
            blocked_at: "2026-10-17T01:02:00Z"
          }
        ]
      }
    end

    snapshot =
      Taskboard.snapshot(
        settings: settings,
        runtime_snapshot_fun: runtime_snapshot
      )

    assert snapshot.columns == ["Todo", "In Progress", "Human Review", "Done"]
    assert snapshot.counts == %{"Todo" => 1, "In Progress" => 1, "Human Review" => 4, "Done" => 0}

    by_id = Map.new(snapshot.cards, &{&1.issue_identifier, &1})
    assert by_id["MOCK-1"].column == "Todo"
    assert by_id["MOCK-2"].column == "In Progress"
    assert by_id["MOCK-2"].agent_status == "running"
    assert by_id["MOCK-3"].column == "Human Review"
    assert by_id["MOCK-3"].agent_status == "review"
    assert by_id["MOCK-4"].column == "Human Review"
    assert by_id["MOCK-4"].agent_status == "blocked"
    assert by_id["MOCK-5"].column == "Human Review"
    assert by_id["MOCK-5"].agent_status == "unverified closure"
    assert by_id["MOCK-5"].needs_human
    assert by_id["MOCK-6"].column == "Human Review"
    assert by_id["MOCK-6"].agent_status == "unverified closure"
    assert by_id["MOCK-6"].needs_human
    assert by_id["MOCK-1"].priority == 2
    assert by_id["MOCK-1"].summary == "Implement the replayed fixture."

    assert snapshot.capabilities == %{
             create_issue: false,
             comment: false,
             dispatch: false,
             retry: false,
             rework: false,
             accept: false,
             pause: false,
             drag_and_drop: false
           }

    assert [
             %{
               kind: "mr",
               label: "Open merge request !9",
               url: "https://example.invalid/merge_requests/9"
             }
           ] = by_id["MOCK-1"].artifacts
  end

  test "projects only Issues assigned to the configured tracker owner", %{settings: settings} do
    assigned = %{issue("20", "MOCK-20", "Assigned", "Todo", ["symphony:ready"]) | assignee_id: "20"}
    another = %{issue("21", "MOCK-21", "Another owner", "Todo", ["symphony:ready"]) | assignee_id: "21"}
    unassigned = issue("22", "MOCK-22", "Unassigned", "Todo", ["symphony:ready"])
    settings = put_in(settings.tracker.assignee, "20")

    snapshot =
      Taskboard.snapshot(
        settings: settings,
        issues_fun: fn _states -> [assigned, another, unassigned] end,
        runtime_snapshot_fun: fn -> %{} end
      )

    assert [%{issue_identifier: "MOCK-20", column: "Todo"}] = snapshot.cards
    assert snapshot.counts == %{"Todo" => 1, "In Progress" => 0, "Human Review" => 0, "Done" => 0}
  end

  test "a retrying runtime entry keeps the Issue in progress while recovery is pending", %{
    settings: settings
  } do
    snapshot =
      Taskboard.snapshot(
        settings: settings,
        runtime_snapshot_fun: fn ->
          %{running: [], retrying: [%{issue_id: "2", identifier: "MOCK-2", attempt: 2}], blocked: []}
        end
      )

    by_id = Map.new(snapshot.cards, &{&1.issue_identifier, &1})

    assert by_id["MOCK-2"].column == "In Progress"
    assert by_id["MOCK-2"].agent_status == "retrying"
    assert by_id["MOCK-2"].runtime.status == "retrying"
  end

  test "detail combines repository content, comments, delivery review, and execution evidence", %{
    settings: settings
  } do
    assert {:ok, detail} =
             Taskboard.issue_detail("memory-mock-issues", "MOCK-1",
               settings: settings,
               runtime_snapshot_fun: fn -> %{} end
             )

    assert detail.issue.identifier == "MOCK-1"
    assert detail.description == "Implement the replayed fixture."
    assert Enum.map(detail.comments, & &1.id) == [11, 12]
    assert Enum.at(detail.comments, 1).engine
    assert [%{kind: "mr", number: 9, unresolved_comments: 2}] = detail.deliveries
    assert detail.execution.thread_id == "thread-mock"

    assert detail.capabilities == %{
             comment: false,
             dispatch: false,
             retry: false,
             rework: false,
             accept: false,
             pause: false
           }
  end

  test "cards expose delivered reports, link identity, and the required human action", %{
    settings: _settings
  } do
    journal_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-taskboard-artifacts-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    workflow =
      Workflow.workflow_file_path()
      |> File.read!()
      |> String.replace(
        "agent:\n",
        "agent:\n  goal_mode: true\n  run_journal_dir: #{Jason.encode!(journal_root)}\n"
      )

    File.write!(Workflow.workflow_file_path(), workflow)

    :ok = WorkflowStore.force_reload()
    on_exit(fn -> File.rm_rf(journal_root) end)

    issue =
      issue(
        "29",
        "GL-29",
        "Report delivery",
        "opened",
        ["symphony:ready", "symphony:review", "type:research"]
      )

    report_url = issue.url <> "#note_101936"
    directory = RunJournal.directory(Execution.journal_root(), issue.id)
    File.mkdir_p!(directory)

    File.write!(
      Path.join(directory, "run.json"),
      Jason.encode!(%{
        "phase" => "completed",
        "attempt_id" => "report-attempt",
        "issue_id" => issue.id,
        "issue_url" => issue.url,
        "workflow" => %{
          "state" => "review",
          "contract" => %{"acceptance_mode" => "separate", "type" => "research"},
          "manifest" => %{
            "contract" => "label:1@1@2026-10-17T00:00:00Z",
            "items" => [
              %{
                "id" => "report",
                "kind" => "report",
                "url" => report_url,
                "version" => "v1",
                "criteria" => ["answer"]
              }
            ]
          }
        },
        "stage_results" => %{"mr_publication" => "not_applicable"},
        "updated_at" => "2026-10-17T01:00:00Z",
        "events" => []
      })
    )

    settings = Config.settings!()

    snapshot =
      Taskboard.snapshot(
        settings: settings,
        issues_fun: fn _states -> [issue] end,
        runtime_snapshot_fun: fn -> %{} end
      )

    assert [
             %{
               artifacts: [%{kind: "report", label: "Open report", url: ^report_url}],
               human_action: %{
                 required: true,
                 label: nil,
                 summary: summary
               }
             }
           ] = snapshot.cards

    assert summary =~ "This task has no MR; that is expected"
    assert summary =~ "Record a decision bound to the current delivery"
    refute summary =~ "symphony:accept"

    assert {:ok, detail} =
             Taskboard.issue_detail("memory-project", "GL-29",
               settings: settings,
               issues_fun: fn _states -> [issue] end,
               runtime_snapshot_fun: fn -> %{} end
             )

    assert detail.execution.manifest["items"] == [
             %{
               "criteria" => ["answer"],
               "id" => "report",
               "kind" => "report",
               "url" => report_url,
               "version" => "v1"
             }
           ]
  end

  test "request cards distinguish GitHub, GitLab, mixed delivery and failure actions" do
    review_issue =
      issue(
        "90",
        "GH-90",
        "Review request",
        "opened",
        ["symphony:ready", "symphony:review", "type:mixed"]
      )

    github = %{id: "github", name: "GitHub", repo: "owner/repo", kind: "github"}

    github_card =
      Taskboard.card_payload(
        review_issue,
        github,
        nil,
        execution_with_items([
          %{"id" => "report", "kind" => "report", "url" => "https://github.test/note/1"},
          %{"id" => "pr", "kind" => "pr", "url" => "https://github.test/owner/repo/pull/7"},
          %{"id" => "request", "kind" => "mr", "url" => "https://github.test/request/8"},
          %{"id" => "missing", "kind" => "mr", "url" => nil}
        ])
      )

    assert Enum.map(github_card.artifacts, & &1.label) == [
             "Open report",
             "Open pull request #7",
             "Open pull request"
           ]

    assert github_card.human_action.summary =~
             "Review the report and PR #7 and the delivery."

    gitlab = %{id: "gitlab", name: "GitLab", repo: "owner/repo", kind: "gitlab"}

    gitlab_multiple =
      Taskboard.card_payload(
        review_issue,
        gitlab,
        nil,
        execution_with_items([
          %{"id" => "mr", "kind" => "mr", "url" => "https://gitlab.test/repo/-/merge_requests/9"},
          %{"id" => "request", "kind" => "mr", "url" => "https://gitlab.test/request/10"}
        ])
      )

    assert Enum.map(gitlab_multiple.artifacts, & &1.label) == [
             "Open merge request !9",
             "Open merge request"
           ]

    assert gitlab_multiple.human_action.summary =~ "Review the linked requests: MR !9 and the delivery."

    gitlab_single =
      Taskboard.card_payload(
        review_issue,
        gitlab,
        nil,
        execution_with_items([
          %{"id" => "mr", "kind" => "mr", "url" => "https://gitlab.test/repo/-/merge_requests/9"}
        ])
      )

    assert gitlab_single.human_action.summary =~ "Review MR !9."

    merge_card =
      Taskboard.card_payload(
        review_issue,
        gitlab,
        nil,
        execution_with_items(
          [%{"id" => "mr", "kind" => "mr", "url" => "https://gitlab.test/repo/-/merge_requests/9"}],
          "merge"
        )
      )

    assert merge_card.human_action.label == nil
    assert merge_card.human_action.summary =~ "Symphony will verify that delivery."

    failed_issue = %{review_issue | labels: ["symphony:ready", "symphony:failed"]}
    failed_card = Taskboard.card_payload(failed_issue, gitlab, nil)
    assert failed_card.human_action.label == "symphony:rework"
    assert failed_card.human_action.summary =~ "the latest agent run failed"
  end

  test "delivery enrichment failures leave the tracker card available" do
    settings = Config.settings!()

    tracker = %{
      settings.tracker
      | kind: "gitlab",
        provider: %{"project_path" => "model-compiler-team/nanocore-hw", "api_key" => "token"},
        active_states: ["opened"],
        terminal_states: ["closed"]
    }

    settings = %{settings | tracker: tracker}

    issue = %{
      issue(
        "30",
        "GL-30",
        "Linked delivery",
        "opened",
        ["wayfinder:task"]
      )
      | id: "not-a-number",
        native_ref: %{"merge_requests_count" => 1}
    }

    assert %{cards: [%{issue_identifier: "GL-30", artifacts: []}]} =
             Taskboard.snapshot(
               settings: settings,
               issues_fun: fn _states -> {:ok, [issue]} end,
               runtime_snapshot_fun: fn -> %{} end,
               request_fun: fn _method, _path, _query, _body, _settings ->
                 flunk("an invalid native Issue number should fail before making a request")
               end
             )
  end

  test "a retired accept label never fabricates acceptance or a human acceptance control", %{
    settings: settings
  } do
    legacy_issue =
      issue("7", "MOCK-7", "Accepted but open", "open", ["symphony:ready", "symphony:accept"])

    project = %{id: "memory", name: "mock", repo: "mock/issues", kind: "memory"}
    card = Taskboard.card_payload(legacy_issue, project, nil)

    assert card.column == "Todo"
    assert card.agent_status == "idle"
    assert card.delivery == nil
    refute card.needs_human
    assert card.human_action == nil

    blocked =
      issue("8", "MOCK-8", "Blocked without runtime", "open", ["symphony:ready", "symphony:blocked"])

    blocked_card = Taskboard.card_payload(blocked, project, nil)
    assert blocked_card.column == "Human Review"
    assert blocked_card.agent_status == "waiting for human"
    assert blocked_card.human_action.required

    opts = [
      settings: settings,
      issues_fun: fn _states -> [legacy_issue] end,
      runtime_snapshot_fun: fn -> %{} end
    ]

    assert {:ok, detail} = Taskboard.issue_detail("memory-mock-issues", "MOCK-7", opts)

    assert detail.capabilities == %{
             comment: false,
             dispatch: false,
             retry: false,
             rework: false,
             accept: false,
             pause: false
           }
  end

  test "a plan member card reads its own WorkRef journal and never grants Done from a cached fact" do
    journal_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-taskboard-lifecycle-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(journal_root) end)

    for provider <- ["github", "gitlab"] do
      work = member_work(provider)
      repository = member_repository(provider)

      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

      plan_path = Workflow.workflow_file_path()

      plan_path
      |> File.read!()
      |> String.replace(
        "tracker:\n",
        "tracker:\n  provider: " <> Jason.encode!(%{"plan_repositories" => [repository]}) <> "\n"
      )
      |> then(&File.write!(plan_path, &1))

      :ok = WorkflowStore.force_reload()

      record =
        write_member_journal(journal_root, work, %{
          "workflow" => %{
            "state" => "waiting",
            "phase" => "completed",
            "closeable" => true,
            "restrictions" => %{},
            "used_ms" => 0,
            "clock_at" => 0,
            "charging" => false,
            "contract" => %{"acceptance_mode" => "technical"},
            "manifest" => %{
              "items" => [
                %{"id" => "report", "kind" => "report", "url" => "https://example.invalid/member-report", "version" => "v1"}
              ]
            }
          }
        })

      # The retired numeric address must never drive a member card: this decoy
      # journal is complete, closeable and carries its own artifact.
      decoy = RunJournal.directory(journal_root, "2")
      File.mkdir_p!(decoy)

      File.write!(
        Path.join(decoy, "run.json"),
        Jason.encode!(%{
          "phase" => "decoy",
          "issue_id" => "2",
          "workflow" => %{"closeable" => true, "manifest" => %{"items" => [%{"id" => "decoy", "kind" => "report", "url" => "https://example.invalid/decoy"}]}}
        })
      )

      snapshot =
        Taskboard.snapshot(
          settings: Config.settings!(),
          issues_fun: fn _states -> [member_issue(provider)] end,
          runtime_snapshot_fun: fn -> %{} end,
          journal_root: journal_root
        )

      assert [card] = snapshot.cards
      assert card.projection.status == "stale"
      assert card.projection.directory == record["directory"]
      assert card.projection.work == work
      assert card.column == "Human Review"
      assert card.agent_status == "stale projection"
      assert card.needs_human
      assert card.human_action.required and card.human_action.summary =~ "stale fact"
      assert Enum.map(card.artifacts, & &1.url) == ["https://example.invalid/member-report"]
      assert {:ok, current} = RunJournal.read(record["directory"])
      assert get_in(current, ["workflow", "closeable"]) == true

      empty =
        Taskboard.snapshot(
          settings: Config.settings!(),
          issues_fun: fn _states -> [member_issue(provider)] end,
          runtime_snapshot_fun: fn -> %{} end,
          journal_root: Path.join(journal_root, "empty")
        )

      assert [unobserved] = empty.cards
      refute unobserved.column == "Done"
    end

    configured = Config.settings!()
    tracker = %{configured.tracker | provider: %{"plan_roots" => [:invalid], "plan_repositories" => [nil]}}
    malformed = %{configured | tracker: tracker}

    assert [_] =
             Taskboard.snapshot(
               settings: malformed,
               issues_fun: fn _states -> [member_issue("github")] end,
               runtime_snapshot_fun: fn -> %{} end,
               journal_root: journal_root
             ).cards

    stale = issue("41", "MOCK-41", "Stale label", "closed", ["symphony:ready", "symphony:accept"])

    snapshot =
      Taskboard.snapshot(
        settings: Config.settings!(),
        issues_fun: fn _states -> [stale] end,
        runtime_snapshot_fun: fn -> %{} end
      )

    assert [stale_card] = snapshot.cards
    assert stale_card.column == "Human Review"
    assert stale_card.agent_status == "unverified closure"
    assert stale_card.needs_human
    assert stale_card.artifacts == []
  end

  test "an Issue on another host cannot inherit a same-path repository journal" do
    root = Path.join(System.tmp_dir!(), "symphony-taskboard-host-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    host_a = member_repository("github")
    host_b = %{host_a | "host" => "other.github.test", "repository_id" => "20", "api_url" => "https://other.github.test/api/v3"}
    host_c = %{host_a | "host" => "github.test:8443", "api_url" => "https://github.test:8443/api/v3"}
    work_a = member_work("github")
    record = write_member_journal(root, work_a, %{})
    work_c = %{work_a | "host" => "github.test:8443"}
    record_c = write_member_journal(root, work_c, %{})

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    path = Workflow.workflow_file_path()

    path
    |> File.read!()
    |> String.replace("tracker:\n", "tracker:\n  provider: " <> Jason.encode!(%{"plan_repositories" => [host_a, host_b, host_c]}) <> "\n")
    |> then(&File.write!(path, &1))

    :ok = WorkflowStore.force_reload()
    issue_b = %{member_issue("github") | url: "https://other.github.test/team/repo/issues/2"}

    for candidate <- [
          issue_b,
          %{issue_b | url: nil},
          %{issue_b | url: "https://other.github.test/team/repo/issues/3"},
          %{issue_b | native_ref: Map.put(issue_b.native_ref, "repository_id", "999")}
        ] do
      snapshot =
        Taskboard.snapshot(
          settings: Config.settings!(),
          issues_fun: fn _states -> [candidate] end,
          runtime_snapshot_fun: fn -> %{} end,
          journal_root: root
        )

      assert [card] = snapshot.cards
      refute is_map(card.projection) and card.projection.directory == record["directory"]
      refute card.column == "Done"
    end

    port_issue = %{member_issue("github") | url: "https://github.test:8443/team/repo/issues/2"}

    port_snapshot =
      Taskboard.snapshot(
        settings: Config.settings!(),
        issues_fun: fn _states -> [port_issue] end,
        runtime_snapshot_fun: fn -> %{} end,
        journal_root: root
      )

    assert [port_card] = port_snapshot.cards
    assert port_card.projection.directory == record_c["directory"]
    refute port_card.projection.directory == record["directory"]
  end

  defp member_work("github"), do: %{"provider" => "github", "host" => "github.test", "repository_id" => "10", "kind" => "issue", "number" => 2}
  defp member_work("gitlab"), do: %{"provider" => "gitlab", "host" => "gitlab.test", "repository_id" => "10", "kind" => "issue", "number" => 2}

  defp member_repository(provider) do
    work = member_work(provider)

    Map.take(work, ~w(provider host repository_id))
    |> Map.merge(%{
      "path" => "team/repo",
      "api_url" => "https://" <> work["host"] <> if(provider == "github", do: "/api/v3", else: "/api/v4"),
      "credential" => "$UNUSED_TASKBOARD_FIXTURE"
    })
  end

  defp member_issue("github") do
    %{issue("2", "GH-2", "Delivered member", "closed", ["symphony:ready"]) | url: "https://github.test/team/repo/issues/2", native_ref: %{"number" => 2, "repo" => "team/repo"}}
  end

  defp member_issue("gitlab") do
    %{issue("2", "GL-2", "Delivered member", "closed", ["symphony:ready"]) | url: "https://gitlab.test/team/repo/-/issues/2", native_ref: %{"iid" => 2, "project_path" => "team/repo"}}
  end

  # The member journal is written through the production journal API into the
  # directory the reconciler uses: RunJournal.directory(root, WorkRef.key(work)).
  defp write_member_journal(root, work, changes) do
    authority = %{
      "work" => Map.put(work, "number", work["number"] + 1),
      "source" => "note:1",
      "actor" => "1",
      "revision" => TaskWorkflow.digest("plan")
    }

    binding = %{
      "work" => work,
      "role" => "developer",
      "plan_revision" => authority["revision"],
      "contract_sha" => TaskWorkflow.digest("contract"),
      "authority" => authority,
      "inputs" => [],
      "candidate" => nil,
      "policy_sha" => TaskWorkflow.digest("policy")
    }

    {:ok, record} = RunJournal.admit(root, WorkRef.key(work), execution_binding: binding)
    {:ok, record} = RunJournal.checkpoint(record, changes)
    :ok = RunJournal.complete(record, "completed")
    record
  end

  test "the retired numeric journal address no longer drives the board", %{
    settings: _settings
  } do
    journal_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-taskboard-lifecycle-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    workflow =
      Workflow.workflow_file_path()
      |> File.read!()
      |> String.replace(
        "agent:\n",
        "agent:\n  goal_mode: true\n  run_journal_dir: #{Jason.encode!(journal_root)}\n"
      )

    File.write!(Workflow.workflow_file_path(), workflow)
    :ok = WorkflowStore.force_reload()
    on_exit(fn -> File.rm_rf(journal_root) end)

    stale = issue("41", "MOCK-41", "Stale label", "closed", ["symphony:ready", "symphony:accept"])
    fabricated = issue("40", "MOCK-40", "Numeric journal", "closed", ["symphony:ready"])

    directory = RunJournal.directory(Execution.journal_root(), fabricated.id)
    File.mkdir_p!(directory)

    File.write!(
      Path.join(directory, "run.json"),
      Jason.encode!(%{
        "phase" => "completed",
        "attempt_id" => "accepted-attempt",
        "issue_id" => fabricated.id,
        "updated_at" => "2026-10-17T01:00:00Z",
        "workflow" => %{
          "state" => "waiting",
          "phase" => "completed",
          "closeable" => true,
          "contract" => %{"acceptance_mode" => "separate"},
          "manifest" => %{"items" => []}
        }
      })
    )

    snapshot =
      Taskboard.snapshot(
        settings: Config.settings!(),
        issues_fun: fn _states -> [fabricated, stale] end,
        runtime_snapshot_fun: fn -> %{} end
      )

    by_id = Map.new(snapshot.cards, &{&1.issue_identifier, &1})

    # Without a plan identity there is no current projection, so a journal that
    # claims `closeable` stays a historical fact in Human Review.
    assert by_id["MOCK-40"].column == "Human Review"
    assert by_id["MOCK-40"].agent_status == "unverified closure"
    assert by_id["MOCK-40"].needs_human

    assert by_id["MOCK-41"].column == "Human Review"
    assert by_id["MOCK-41"].agent_status == "unverified closure"
    assert by_id["MOCK-41"].needs_human
    assert by_id["MOCK-41"].artifacts == []
  end

  test "retired write entry points reject mutations and never touch the tracker", %{
    settings: settings
  } do
    opts = [settings: settings, runtime_snapshot_fun: fn -> %{} end]

    for {identifier, action, attrs} <- [
          {"MOCK-1", "dispatch", %{}},
          {"MOCK-2", "pause", %{}},
          {"MOCK-2", "retry", %{}},
          {"MOCK-3", "rework", %{"comment" => "Please address the failing case."}},
          {"MOCK-3", "accept", %{}}
        ] do
      assert {:error, :taskboard_read_only} =
               Taskboard.perform_action("memory-mock-issues", identifier, action, attrs, opts)
    end

    assert {:error, :taskboard_read_only} =
             Taskboard.create_issue(
               "memory-mock-issues",
               %{"title" => "Mock Issue", "description" => "Body", "labels" => ["type:research"]},
               opts
             )

    assert {:error, :taskboard_read_only} =
             Taskboard.comment("memory-mock-issues", "MOCK-1", "A human reply", opts)

    assert {:error, :taskboard_read_only} =
             Taskboard.perform_action("memory-mock-issues", "MOCK-1", "archive", %{}, opts)

    refute_receive {:taskboard_mutation, _}
  end

  test "Taskboard config resolves operator, provider, and remote control secrets" do
    System.put_env("SYMPHONY_TASKBOARD_CONTROL_TEST", "control-secret")
    System.put_env("SYMPHONY_TASKBOARD_PROVIDER_TEST", "human-secret")
    System.put_env("SYMPHONY_TASKBOARD_REMOTE_TEST", "remote-secret")

    on_exit(fn ->
      System.delete_env("SYMPHONY_TASKBOARD_CONTROL_TEST")
      System.delete_env("SYMPHONY_TASKBOARD_PROVIDER_TEST")
      System.delete_env("SYMPHONY_TASKBOARD_REMOTE_TEST")
    end)

    remote = %{
      "id" => "remote-workspace",
      "name" => "Workspace",
      "kind" => "github",
      "repo" => "maychair/workspace",
      "url" => "http://symphony-workspace.test:8093",
      "token" => "$SYMPHONY_TASKBOARD_REMOTE_TEST"
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      taskboard_enabled: true,
      taskboard_refresh_ms: 4_000,
      taskboard_control_token: "$SYMPHONY_TASKBOARD_CONTROL_TEST",
      taskboard_provider_token: "$SYMPHONY_TASKBOARD_PROVIDER_TEST",
      taskboard_projects: [remote],
      server_host: "0.0.0.0"
    )

    assert :ok = Config.validate!()
    config = Config.settings!()
    assert config.taskboard.enabled
    assert config.taskboard.refresh_ms == 4_000
    assert config.taskboard.control_token == "control-secret"
    assert config.taskboard.provider_token == "human-secret"
    assert [%{"token" => "remote-secret"}] = config.taskboard.projects
    assert config.server.host == "0.0.0.0"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      taskboard_projects: [remote, remote]
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "project IDs must be unique"
  end

  test "Taskboard schema rejects malformed remote project entries without crashing" do
    changeset =
      TaskboardSchema.changeset(%TaskboardSchema{}, %{
        "enabled" => true,
        "refresh_ms" => 1_000,
        "projects" => [
          %{
            "id" => "duplicate",
            "kind" => "github",
            "repo" => "owner/repo",
            "url" => "https:"
          },
          %{
            "id" => "duplicate",
            "kind" => "jira",
            "repo" => "",
            "url" => 42
          }
        ]
      })

    refute changeset.valid?
    messages = Enum.map(changeset.errors, fn {_field, {message, _meta}} -> message end)

    assert Enum.any?(messages, &(&1 == "projects[0].url must be an HTTP(S) URL"))
    assert Enum.any?(messages, &(&1 == "projects[1].kind must be github or gitlab"))
    assert Enum.any?(messages, &(&1 == "projects[1].repo must be a non-empty string"))
    assert Enum.any?(messages, &(&1 == "projects[1].url must be an HTTP(S) URL"))
    assert Enum.any?(messages, &(&1 == "project IDs must be unique"))

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{
               "tracker" => %{
                 "kind" => "memory",
                 "provider" => %{"repo" => "owner/repo"}
               },
               "taskboard" => %{"projects" => ["not-a-project"]}
             })

    assert message =~ "projects"
  end

  test "aggregates explicitly configured remote Symphony projects without a second task store", %{
    settings: settings
  } do
    remote = %{
      "id" => "remote-workspace",
      "name" => "Workspace",
      "kind" => "github",
      "repo" => "maychair/workspace",
      "url" => "http://symphony-workspace.test:8093",
      "token" => "remote-control"
    }

    taskboard = %{settings.taskboard | projects: [remote]}
    settings = %{settings | taskboard: taskboard}

    remote_fun = fn url, headers ->
      assert headers == [{"x-symphony-taskboard-token", "remote-control"}]
      assert url == "http://symphony-workspace.test:8093/api/v1/taskboard/projects/remote-workspace"

      {:ok,
       %{
         status: 200,
         body: %{
           "cards" => [
             %{
               "issue_identifier" => "GH-42",
               "title" => "Remote Issue",
               "column" => "Todo",
               "project_id" => "remote-workspace",
               "repo" => "maychair/workspace",
               "kind" => "github",
               "labels" => ["symphony:ready"],
               "agent_status" => "idle"
             }
           ]
         }
       }}
    end

    snapshot =
      Taskboard.snapshot(
        settings: settings,
        runtime_snapshot_fun: fn -> %{} end,
        remote_request_fun: remote_fun
      )

    assert Enum.map(snapshot.projects, & &1.id) == ["memory-mock-issues", "remote-workspace"]
    assert Enum.any?(snapshot.cards, &(&1.issue_identifier == "GH-42" and &1.project_id == "remote-workspace"))

    read_only = %{settings | taskboard: %{settings.taskboard | provider_token: nil}}

    read_only_snapshot =
      Taskboard.snapshot(
        settings: read_only,
        runtime_snapshot_fun: fn -> %{} end,
        remote_request_fun: remote_fun
      )

    refute read_only_snapshot.capabilities.drag_and_drop
    refute read_only_snapshot.capabilities.create_issue
  end

  test "remote action requests are rejected before any network mutation", %{
    settings: settings
  } do
    remote = %{
      "id" => "remote-workspace",
      "name" => "Workspace",
      "kind" => "github",
      "repo" => "maychair/workspace",
      "url" => "http://symphony-workspace.test:8093",
      "token" => "remote-control"
    }

    taskboard = %{settings.taskboard | projects: [remote]}
    settings = %{settings | taskboard: taskboard}

    remote_fun = fn url, headers ->
      flunk("a read-only Taskboard must not call #{url} with #{inspect(headers)}")
    end

    opts = [
      settings: settings,
      runtime_snapshot_fun: fn -> %{} end,
      remote_request_fun: remote_fun
    ]

    assert {:error, :taskboard_read_only} =
             Taskboard.perform_action("remote-workspace", "GH-42", "dispatch", %{}, opts)

    assert {:error, :taskboard_read_only} =
             Taskboard.perform_action("remote-workspace", "GH-42", "accept", %{}, opts)

    assert {:error, :taskboard_read_only} =
             Taskboard.create_issue("remote-workspace", %{"title" => "Remote draft"}, opts)

    assert {:error, :taskboard_read_only} =
             Taskboard.comment("remote-workspace", "GH-42", "Reply", opts)
  end

  test "public entry points use configured settings and keep the projection read-only" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      taskboard_enabled: true,
      taskboard_control_token: "operator-control",
      taskboard_provider_token: "operator-provider"
    )

    settings = Config.settings!()
    project_id = "memory-project"

    assert Taskboard.columns() == ["Todo", "In Progress", "Human Review", "Done"]
    assert Taskboard.runtime_status(nil) == "idle"
    assert Taskboard.runtime_status(%{status: "running"}) == "running"
    assert Taskboard.runtime_status(%{worker: "local"}) == "active"
    assert Taskboard.write_enabled?(settings)
    assert Taskboard.authorized?(settings, "operator-control")
    refute Taskboard.authorized?(settings, "wrong-control")

    assert %{columns: [_, _, _, _], cards: cards, capabilities: capabilities} = Taskboard.snapshot()
    assert cards != []
    assert capabilities.create_issue == false
    assert capabilities.drag_and_drop == false
    assert {:ok, %{project: %{id: ^project_id}, errors: []}} = Taskboard.project_snapshot(project_id)
    assert {:ok, %{issue: %{identifier: "MOCK-1"}}} = Taskboard.issue_detail(project_id, "MOCK-1")

    assert {:error, :taskboard_read_only} =
             Taskboard.create_issue(project_id, %{"title" => "Default wrapper"})

    assert {:error, :taskboard_read_only} =
             Taskboard.comment(project_id, "MOCK-1", "Default comment")

    assert {:error, :taskboard_read_only} =
             Taskboard.perform_action(project_id, "MOCK-1", "dispatch", %{})
  end

  test "project projections tolerate malformed runtime and provider results" do
    settings = settings()
    project_id = "memory-mock-issues"
    valid_issue = hd(issues())

    unsupported = %{settings | tracker: %{settings.tracker | kind: "unsupported"}}

    snapshot =
      Taskboard.snapshot(
        settings: unsupported,
        runtime_snapshot_fun: fn -> %{} end
      )

    assert [%{project_id: "unsupported-mock-issues", error: error}] = snapshot.errors
    assert error =~ "unsupported_taskboard_tracker"

    assert {:ok, %{errors: [error]}} =
             Taskboard.project_snapshot("unsupported-mock-issues",
               settings: unsupported,
               runtime_snapshot_fun: fn -> %{} end
             )

    assert error =~ "unsupported_taskboard_tracker"
    assert {:error, :taskboard_project_not_found} = Taskboard.project_snapshot("missing", settings: settings)

    assert {:ok, %{cards: [card]}} =
             Taskboard.project_snapshot(project_id,
               settings: settings,
               issues_fun: fn _states -> [valid_issue, :ignored] end,
               runtime_snapshot_fun: fn -> :not_a_snapshot end
             )

    assert card.issue_identifier == "MOCK-1"

    assert {:ok, %{cards: cards}} =
             Taskboard.project_snapshot(project_id,
               settings: settings,
               runtime_snapshot_fun: :not_a_function
             )

    assert length(cards) == 6

    card =
      Taskboard.card_payload(
        issue("8", "MOCK-8", "Normalized labels", "open", [nil, " SYMPHONY:RUNNING "]),
        %{id: "memory", name: "mock", repo: "mock/issues", kind: "memory"},
        nil
      )

    assert card.column == "In Progress"
    assert card.labels == ["", "symphony:running"]
  end

  test "Issue detail reads bounded execution evidence from the local journal" do
    journal_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-taskboard-journal-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    workflow =
      Workflow.workflow_file_path()
      |> File.read!()
      |> String.replace(
        "agent:\n",
        "agent:\n  goal_mode: true\n  run_journal_dir: #{Jason.encode!(journal_root)}\n"
      )

    File.write!(Workflow.workflow_file_path(), workflow)
    :ok = WorkflowStore.force_reload()

    directory = SymphonyElixir.RunJournal.directory(journal_root, "MOCK-1")
    File.mkdir_p!(directory)

    File.write!(
      Path.join(directory, "run.json"),
      Jason.encode!(%{
        "phase" => "review",
        "attempt_id" => "attempt-1",
        "attempt_count" => 2,
        "thread_id" => "thread-1",
        "turn_id" => "turn-1",
        "blocker_reason" => nil,
        "handoff" => %{"kind" => "review"},
        "updated_at" => "2026-10-17T01:00:00Z",
        "events" => for(index <- 1..30, do: %{"event" => index})
      })
    )

    settings = Config.settings!()
    details = Application.get_env(:symphony_elixir, :taskboard_memory_details)

    Application.put_env(
      :symphony_elixir,
      :taskboard_memory_details,
      Map.update!(details, "MOCK-1", &Map.delete(&1, "execution"))
    )

    assert {:ok, %{execution: execution}} =
             Taskboard.issue_detail("memory-project", "MOCK-1", settings: settings)

    assert execution.thread_id == "thread-1"
    assert length(execution.events) == 20
    assert execution.events |> hd() |> Map.fetch!("event") == 11

    File.write!(Path.join(directory, "run.json"), "{")

    assert {:ok, %{execution: nil}} =
             Taskboard.issue_detail("memory-project", "MOCK-1", settings: settings)
  end

  test "remote projections normalize cards and expose remote failures" do
    remote = remote_project()
    settings = %{settings() | taskboard: %{settings().taskboard | projects: [remote]}}

    remote_fun = fn
      url, [{"x-symphony-taskboard-token", "remote-control"}] ->
        cond do
          String.ends_with?(url, "/projects/remote-workspace") ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "cards" => [
                   "not-a-card",
                   %{
                     "issue_identifier" => "GH-9",
                     "column" => "Unknown",
                     "labels" => [nil],
                     "updated_at" => "not-a-time"
                   }
                 ]
               }
             }}

          String.ends_with?(url, "/issues/remote-workspace/GH-9") ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "issue" => %{"identifier" => "GH-9", "title" => "Remote"},
                 "comments" => [
                   %{
                     "id" => 1,
                     "author" => "human",
                     "body" => "Reviewed",
                     "engine" => true,
                     "system" => false
                   }
                 ],
                 "deliveries" => []
               }
             }}
        end
    end

    snapshot =
      Taskboard.snapshot(
        settings: settings,
        runtime_snapshot_fun: fn -> %{} end,
        remote_request_fun: remote_fun
      )

    assert Enum.any?(snapshot.cards, &(&1.issue_identifier == "GH-9" and &1.project_id == "remote-workspace"))
    assert Enum.any?(snapshot.cards, &(&1.project_id == "remote-workspace" and &1.column == "Todo"))

    assert {:ok, %{comments: [%{author: "human", engine: true}]}} =
             Taskboard.issue_detail("remote-workspace", "GH-9",
               settings: settings,
               remote_request_fun: remote_fun
             )

    malformed =
      Taskboard.snapshot(
        settings: settings,
        runtime_snapshot_fun: fn -> %{} end,
        remote_request_fun: fn _, _ -> {:ok, %{status: 200, body: "not-a-map"}} end
      )

    assert Enum.any?(malformed.errors, &(&1.error =~ "invalid_remote_taskboard_payload"))

    unavailable =
      Taskboard.snapshot(
        settings: settings,
        runtime_snapshot_fun: fn -> %{} end,
        remote_request_fun: fn _, _ -> {:error, :offline} end
      )

    assert Enum.any?(unavailable.errors, &(&1.error == ":offline"))

    failed =
      Taskboard.snapshot(
        settings: settings,
        runtime_snapshot_fun: fn -> %{} end,
        remote_request_fun: fn _, _ ->
          {:ok, %{status: 503, body: %{"error" => %{"message" => "unavailable"}}}}
        end
      )

    assert Enum.any?(failed.errors, &(&1.error == "HTTP 503: unavailable"))

    assert {:ok, %{errors: [illegal_response]}} =
             Taskboard.project_snapshot("remote-workspace",
               settings: settings,
               remote_request_fun: fn _, _ -> :bad end
             )

    assert illegal_response =~ "invalid_remote_taskboard_response"

    assert {:ok, %{errors: [raised_response]}} =
             Taskboard.project_snapshot("remote-workspace",
               settings: settings,
               remote_request_fun: fn _, _ -> raise "transport exploded" end
             )

    assert raised_response =~ "transport exploded"

    assert {:error, :invalid_remote_taskboard_payload} =
             Taskboard.issue_detail("remote-workspace", "GH-9",
               settings: settings,
               remote_request_fun: fn _, _ -> {:ok, %{status: 200, body: "bad"}} end
             )

    assert {:error, :offline} =
             Taskboard.issue_detail("remote-workspace", "GH-9",
               settings: settings,
               remote_request_fun: fn _, _ -> {:error, :offline} end
             )
  end

  test "remote projections use GET through the default HTTP client" do
    settings = settings()

    {port, server} = start_http_server([%{"cards" => []}])

    remote =
      remote_project()
      |> Map.put("url", "http://127.0.0.1:#{port}")

    read_settings = %{
      settings
      | taskboard: %{settings.taskboard | projects: [Map.put(remote, "token", nil)]}
    }

    assert %{errors: []} =
             Taskboard.snapshot(
               settings: read_settings,
               runtime_snapshot_fun: fn -> %{} end
             )

    assert :ok = Task.await(server, 5_000)
  end

  defp settings do
    settings = Config.settings!()

    tracker = %{
      settings.tracker
      | provider: %{"repo" => "mock/issues", "project_path" => "mock/issues"},
        required_labels: ["symphony:ready"]
    }

    taskboard = %{
      settings.taskboard
      | enabled: true,
        control_token: "operator-control",
        provider_token: "operator-provider",
        projects: []
    }

    %{settings | tracker: tracker, taskboard: taskboard}
  end

  defp issues do
    [
      issue("1", "MOCK-1", "Todo issue", "Todo", ["symphony:ready", "priority:p2"]),
      issue("2", "MOCK-2", "Running issue", "In Progress", ["symphony:ready", "symphony:running"]),
      issue("3", "MOCK-3", "Review issue", "In Progress", ["symphony:ready", "symphony:review"]),
      issue("4", "MOCK-4", "Blocked issue", "In Progress", ["symphony:ready", "symphony:blocked"]),
      issue("5", "MOCK-5", "Accepted issue", "closed", ["symphony:ready", "symphony:accept"]),
      issue("6", "MOCK-6", "Closed without acceptance", "closed", ["symphony:ready"])
    ]
  end

  defp issue(id, identifier, title, state, labels) do
    %Issue{
      id: id,
      identifier: identifier,
      title: title,
      description: "Implement the replayed fixture.",
      state: state,
      url: "https://example.invalid/issues/#{id}",
      labels: labels,
      dispatchable: true,
      created_at: ~U[2026-10-17 00:00:00Z],
      updated_at: ~U[2026-10-17 01:00:00Z]
    }
  end

  defp execution_with_items(items, acceptance_mode \\ "separate") do
    %{
      manifest: %{"items" => items},
      delivery: nil,
      intermediate: nil,
      acceptance_mode: acceptance_mode
    }
  end

  defp remote_project do
    %{
      "id" => "remote-workspace",
      "name" => "Workspace",
      "kind" => "github",
      "repo" => "maychair/workspace",
      "url" => "http://symphony-workspace.test:8093",
      "token" => "remote-control"
    }
  end

  defp start_http_server(payloads) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, {:active, false}, {:reuseaddr, true}, {:ip, {127, 0, 0, 1}}])

    {:ok, port} = :inet.port(listener)

    task =
      Task.async(fn ->
        Enum.each(payloads, fn payload ->
          {:ok, socket} = :gen_tcp.accept(listener, 5_000)
          {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)
          body = Jason.encode!(payload)

          response =
            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n" <>
              "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body

          :ok = :gen_tcp.send(socket, response)
          :ok = :gen_tcp.close(socket)
        end)

        :gen_tcp.close(listener)
        :ok
      end)

    {port, task}
  end
end
