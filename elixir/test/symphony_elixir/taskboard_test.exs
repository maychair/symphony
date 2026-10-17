defmodule SymphonyElixir.TaskboardTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.Taskboard, as: TaskboardSchema
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

  test "projects Issues into exactly four columns and keeps external closure in Human Review", %{
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
    assert snapshot.counts == %{"Todo" => 1, "In Progress" => 1, "Human Review" => 3, "Done" => 1}

    by_id = Map.new(snapshot.cards, &{&1.issue_identifier, &1})
    assert by_id["MOCK-1"].column == "Todo"
    assert by_id["MOCK-2"].column == "In Progress"
    assert by_id["MOCK-2"].agent_status == "running"
    assert by_id["MOCK-3"].column == "Human Review"
    assert by_id["MOCK-3"].agent_status == "review"
    assert by_id["MOCK-4"].column == "Human Review"
    assert by_id["MOCK-4"].agent_status == "blocked"
    assert by_id["MOCK-5"].column == "Done"
    assert by_id["MOCK-6"].column == "Human Review"
    assert by_id["MOCK-1"].priority == 2
    assert by_id["MOCK-1"].summary == "Implement the replayed fixture."
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
    assert detail.capabilities.comment
  end

  test "an accepted open Issue waits for native closure instead of appearing Done", %{
    settings: settings
  } do
    accepted_issue =
      issue("7", "MOCK-7", "Accepted but open", "open", ["symphony:ready", "symphony:accept"])

    card =
      Taskboard.card_payload(
        accepted_issue,
        %{id: "memory", name: "mock", repo: "mock/issues", kind: "memory"},
        nil
      )

    assert card.column == "Human Review"
    assert card.agent_status == "accepted; awaiting closure"

    opts = [
      settings: settings,
      issues_fun: fn _states -> [accepted_issue] end,
      runtime_snapshot_fun: fn -> %{} end,
      refresh_fun: fn -> :ok end
    ]

    assert {:ok, detail} =
             Taskboard.issue_detail("memory-mock-issues", "MOCK-7", opts)

    refute detail.capabilities.accept
    refute detail.capabilities.rework
    assert detail.capabilities.comment

    assert {:error, :invalid_taskboard_transition} =
             Taskboard.perform_action("memory-mock-issues", "MOCK-7", "accept", %{}, opts)

    assert {:error, :invalid_taskboard_transition} =
             Taskboard.perform_action("memory-mock-issues", "MOCK-7", "rework", %{}, opts)
  end

  test "operator writes preserve labels as explicit state transitions", %{settings: settings} do
    opts = [
      settings: settings,
      runtime_snapshot_fun: fn -> %{} end,
      refresh_fun: fn -> :ok end
    ]

    assert {:ok, %{detail: "queued for dispatch"}} =
             Taskboard.perform_action("memory-mock-issues", "MOCK-1", "dispatch", %{}, opts)

    assert_receive {:taskboard_mutation, {:add_label, "MOCK-1", "symphony:ready"}}

    assert {:ok, %{detail: "rework requested"}} =
             Taskboard.perform_action(
               "memory-mock-issues",
               "MOCK-3",
               "rework",
               %{"comment" => "Please address the failing case."},
               opts
             )

    assert_receive {:taskboard_mutation, {:comment, "MOCK-3", "Please address the failing case.", _}}
    assert_receive {:taskboard_mutation, {:remove_label, "MOCK-3", "symphony:rework"}}
    assert_receive {:taskboard_mutation, {:add_label, "MOCK-3", "symphony:rework"}}

    assert {:ok, %{detail: "acceptance requested"}} =
             Taskboard.perform_action("memory-mock-issues", "MOCK-3", "accept", %{}, opts)

    assert_receive {:taskboard_mutation, {:add_label, "MOCK-3", "symphony:accept"}}

    assert {:error, :invalid_taskboard_transition} =
             Taskboard.perform_action("memory-mock-issues", "MOCK-1", "accept", %{}, opts)
  end

  test "create and comment use the operator provider identity and stay read-only without it", %{
    settings: settings
  } do
    opts = [settings: settings, runtime_snapshot_fun: fn -> %{} end, refresh_fun: fn -> :ok end]

    assert {:ok, %{"identifier" => "MOCK-" <> _}} =
             Taskboard.create_issue(
               "memory-mock-issues",
               %{"title" => "Mock Issue", "description" => "Body", "labels" => ["type:research"]},
               opts
             )

    assert_receive {:taskboard_mutation, {:create_issue, %{"title" => "Mock Issue"}, _}}

    assert {:ok, %{body: "A human reply"}} =
             Taskboard.comment("memory-mock-issues", "MOCK-1", "A human reply", opts)

    assert_receive {:taskboard_mutation, {:comment, "MOCK-1", "A human reply", _}}

    taskboard = %{settings.taskboard | provider_token: nil}
    read_only_settings = %{settings | taskboard: taskboard}

    assert {:error, :operator_identity_not_configured} =
             Taskboard.comment("memory-mock-issues", "MOCK-1", "No identity", settings: read_only_settings)
  end

  test "retry uses the controlled orchestrator entry only while automatic recovery is pending", %{
    settings: settings
  } do
    retry_fun = fn issue_id ->
      send(self(), {:retry_now, issue_id})
      :ok
    end

    opts = [
      settings: settings,
      runtime_snapshot_fun: fn ->
        %{
          running: [],
          blocked: [],
          retrying: [%{issue_id: "2", identifier: "MOCK-2", attempt: 2}]
        }
      end,
      refresh_fun: fn -> :ok end,
      retry_fun: retry_fun
    ]

    assert {:ok, %{detail: "retry started"}} =
             Taskboard.perform_action("memory-mock-issues", "MOCK-2", "retry", %{}, opts)

    assert_receive {:retry_now, "2"}

    assert {:error, :invalid_taskboard_transition} =
             Taskboard.perform_action("memory-mock-issues", "MOCK-1", "retry", %{}, opts)

    refute_receive {:retry_now, "1"}
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

    remote_fun = fn :get, url, _body, headers ->
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

    read_only_taskboard = %{settings.taskboard | provider_token: nil}
    read_only_local = %{settings | taskboard: read_only_taskboard}

    remote_only_writes =
      Taskboard.snapshot(
        settings: read_only_local,
        runtime_snapshot_fun: fn -> %{} end,
        remote_request_fun: remote_fun
      )

    assert remote_only_writes.capabilities.drag_and_drop
    assert remote_only_writes.capabilities.create_issue
  end

  test "remote control actions keep the same transition validation and controlled API path", %{
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

    remote_fun = fn
      :get, url, _body, headers ->
        assert headers == [{"x-symphony-taskboard-token", "remote-control"}]

        assert url ==
                 "http://symphony-workspace.test:8093/api/v1/taskboard/issues/remote-workspace/GH-42"

        {:ok,
         %{
           status: 200,
           body: %{
             "issue" => %{
               "identifier" => "GH-42",
               "title" => "Remote Issue",
               "description" => "Remote body",
               "state" => "open",
               "labels" => ["symphony:ready"]
             },
             "project" => %{
               "id" => "remote-workspace",
               "name" => "Workspace",
               "kind" => "github",
               "repo" => "maychair/workspace"
             },
             "comments" => [],
             "deliveries" => []
           }
         }}

      :post, url, body, headers ->
        assert headers == [{"x-symphony-taskboard-token", "remote-control"}]

        assert url ==
                 "http://symphony-workspace.test:8093/api/v1/taskboard/issues/remote-workspace/GH-42/actions/dispatch"

        assert body == %{}
        {:ok, %{status: 200, body: %{"detail" => "queued for dispatch"}}}
    end

    opts = [
      settings: settings,
      runtime_snapshot_fun: fn -> %{} end,
      refresh_fun: fn -> :ok end,
      remote_request_fun: remote_fun
    ]

    assert {:ok, %{:action => "dispatch", "detail" => "queued for dispatch"}} =
             Taskboard.perform_action("remote-workspace", "GH-42", "dispatch", %{}, opts)

    assert {:error, :invalid_taskboard_transition} =
             Taskboard.perform_action("remote-workspace", "GH-42", "accept", %{}, opts)
  end

  test "public entry points use configured settings and expose explicit write controls" do
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

    assert %{columns: [_, _, _, _], cards: cards} = Taskboard.snapshot()
    assert cards != []
    assert {:ok, %{project: %{id: ^project_id}, errors: []}} = Taskboard.project_snapshot(project_id)
    assert {:ok, %{issue: %{identifier: "MOCK-1"}}} = Taskboard.issue_detail(project_id, "MOCK-1")

    assert {:ok, %{"identifier" => "MOCK-" <> _}} =
             Taskboard.create_issue(project_id, %{"title" => "Default wrapper"})

    assert {:ok, %{body: "Default comment"}} = Taskboard.comment(project_id, "MOCK-1", "Default comment")

    assert {:ok, %{detail: "queued for dispatch"}} =
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

  test "local actions reject invalid transitions and preserve provider failures" do
    settings = settings()
    project_id = "memory-mock-issues"

    opts = [
      settings: settings,
      runtime_snapshot_fun: fn -> %{} end,
      refresh_fun: fn -> :ok end
    ]

    assert {:ok, %{detail: "routing authorization removed"}} =
             Taskboard.perform_action(project_id, "MOCK-2", "pause", %{}, opts)

    assert_receive {:taskboard_mutation, {:remove_label, "MOCK-2", "symphony:ready"}}

    assert {:error, :unsupported_taskboard_action} =
             Taskboard.perform_action(project_id, "MOCK-1", "archive", %{}, opts)

    assert {:error, :comment_body_required} =
             Taskboard.comment(project_id, "MOCK-1", nil, opts)

    details = Application.get_env(:symphony_elixir, :taskboard_memory_details)

    Application.put_env(
      :symphony_elixir,
      :taskboard_memory_details,
      Map.put(details, "MOCK-3", %{"runtime_entry" => %{status: "review"}})
    )

    Application.put_env(
      :symphony_elixir,
      :taskboard_memory_mutator,
      fn _event -> {:error, :provider_unavailable} end
    )

    assert {:error, :provider_unavailable} =
             Taskboard.perform_action(
               project_id,
               "MOCK-3",
               "rework",
               %{"comment" => "Provider failure"},
               opts
             )
  end

  test "retry action reports each controlled recovery outcome" do
    settings = settings()
    project_id = "memory-mock-issues"

    opts = fn retry_fun ->
      [
        settings: settings,
        runtime_snapshot_fun: fn ->
          %{running: [], blocked: [], retrying: [%{issue_id: "2", identifier: "MOCK-2"}]}
        end,
        refresh_fun: fn -> :ok end,
        retry_fun: retry_fun
      ]
    end

    assert {:error, :issue_not_retrying} =
             Taskboard.perform_action(project_id, "MOCK-2", "retry", %{}, opts.(fn _ -> :not_retrying end))

    assert {:error, :orchestrator_unavailable} =
             Taskboard.perform_action(project_id, "MOCK-2", "retry", %{}, opts.(fn _ -> :unavailable end))

    assert {:error, :retry_denied} =
             Taskboard.perform_action(
               project_id,
               "MOCK-2",
               "retry",
               %{},
               opts.(fn _ -> {:error, :retry_denied} end)
             )

    assert {:error, :retry_unavailable} =
             Taskboard.perform_action(project_id, "MOCK-2", "retry", %{}, opts.(fn _ -> :unknown end))
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
      :get, url, _body, [{"x-symphony-taskboard-token", "remote-control"}] ->
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
        remote_request_fun: fn _, _, _, _ -> {:ok, %{status: 200, body: "not-a-map"}} end
      )

    assert Enum.any?(malformed.errors, &(&1.error =~ "invalid_remote_taskboard_payload"))

    unavailable =
      Taskboard.snapshot(
        settings: settings,
        runtime_snapshot_fun: fn -> %{} end,
        remote_request_fun: fn _, _, _, _ -> {:error, :offline} end
      )

    assert Enum.any?(unavailable.errors, &(&1.error == ":offline"))

    failed =
      Taskboard.snapshot(
        settings: settings,
        runtime_snapshot_fun: fn -> %{} end,
        remote_request_fun: fn _, _, _, _ ->
          {:ok, %{status: 503, body: %{"error" => %{"message" => "unavailable"}}}}
        end
      )

    assert Enum.any?(failed.errors, &(&1.error == "HTTP 503: unavailable"))

    assert {:error, :invalid_remote_taskboard_payload} =
             Taskboard.issue_detail("remote-workspace", "GH-9",
               settings: settings,
               remote_request_fun: fn _, _, _, _ -> {:ok, %{status: 200, body: "bad"}} end
             )

    assert {:error, :offline} =
             Taskboard.issue_detail("remote-workspace", "GH-9",
               settings: settings,
               remote_request_fun: fn _, _, _, _ -> {:error, :offline} end
             )
  end

  test "remote creation and comments use the controlled API and report invalid responses" do
    remote = remote_project()
    settings = %{settings() | taskboard: %{settings().taskboard | projects: [remote]}}

    remote_fun = fn
      :post, url, body, [{"x-symphony-taskboard-token", "remote-control"}] ->
        cond do
          String.ends_with?(url, "/api/v1/taskboard/issues") ->
            assert body == %{
                     "project_id" => "remote-workspace",
                     "title" => "Remote draft",
                     "description" => "Body",
                     "labels" => ["type:research"]
                   }

            {:ok, %{status: 201, body: %{"identifier" => "GH-10"}}}

          String.ends_with?(url, "/issues/remote-workspace/GH-9/comments") ->
            assert body == %{"body" => "Remote comment"}
            {:ok, %{status: 201, body: %{"id" => 2}}}
        end
    end

    assert {:ok, %{"identifier" => "GH-10"}} =
             Taskboard.create_issue(
               "remote-workspace",
               %{"title" => "Remote draft", "description" => "Body", "labels" => ["type:research"]},
               settings: settings,
               remote_request_fun: remote_fun,
               refresh_fun: fn -> :ok end
             )

    assert {:ok, %{"id" => 2}} =
             Taskboard.comment("remote-workspace", "GH-9", "Remote comment",
               settings: settings,
               remote_request_fun: remote_fun,
               refresh_fun: fn -> :ok end
             )

    assert {:error, :invalid_remote_taskboard_response} =
             Taskboard.create_issue("remote-workspace", %{"title" => "Bad response"},
               settings: settings,
               remote_request_fun: fn _, _, _, _ -> :bad end
             )

    assert {:error, {:taskboard_request_failed, "transport exploded"}} =
             Taskboard.create_issue("remote-workspace", %{"title" => "Raised response"},
               settings: settings,
               remote_request_fun: fn _, _, _, _ -> raise "transport exploded" end
             )
  end

  test "remote operations use GET and POST through the default HTTP client" do
    settings = settings()

    {port, server} =
      start_http_server([
        %{"cards" => []},
        %{"identifier" => "GH-11"}
      ])

    remote =
      remote_project()
      |> Map.put("url", "http://127.0.0.1:#{port}")

    read_settings = %{
      settings
      | taskboard: %{settings.taskboard | projects: [Map.put(remote, "token", nil)]}
    }

    write_settings = %{
      settings
      | taskboard: %{settings.taskboard | projects: [remote]}
    }

    assert %{errors: []} =
             Taskboard.snapshot(
               settings: read_settings,
               runtime_snapshot_fun: fn -> %{} end
             )

    assert {:ok, %{"identifier" => "GH-11"}} =
             Taskboard.create_issue("remote-workspace", %{"title" => "HTTP request"}, settings: write_settings)

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
