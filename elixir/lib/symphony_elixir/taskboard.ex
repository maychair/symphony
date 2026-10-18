defmodule SymphonyElixir.Taskboard do
  @moduledoc """
  Read-only repository Issue board projection for the Symphony Dashboard.

  The Taskboard is a view over tracker Issues and execution observations. It
  keeps no task database and never mutates a tracker: every write stays in the
  native GitHub or GitLab Issue. `Done` and `accepted` come from the versioned
  member lifecycle, never from a `symphony:accept` label.
  """

  require Logger

  alias SymphonyElixir.{Config, Execution, Orchestrator, RunJournal}
  alias SymphonyElixir.Taskboard.Provider
  alias SymphonyElixir.Tracker.Issue

  @columns ["Todo", "In Progress", "Human Review", "Done"]
  @remote_timeout_ms 8_000

  @type result(t) :: {:ok, t} | {:error, term()}

  @spec columns() :: [String.t()]
  def columns, do: @columns

  @spec snapshot(keyword()) :: map()
  def snapshot(opts \\ []) do
    settings = Keyword.get_lazy(opts, :settings, fn -> Config.settings!() end)

    projects =
      settings
      |> project_entries(opts)
      |> Enum.map(&project_snapshot_entry(&1, opts))

    cards =
      projects
      |> Enum.flat_map(&Map.get(&1, :cards, []))
      |> sort_cards()

    errors =
      projects
      |> Enum.flat_map(fn project ->
        case Map.get(project, :error) do
          nil -> []
          error -> [%{project_id: project.id, project: project.name, error: error}]
        end
      end)

    counts =
      Map.new(@columns, fn column ->
        {column, Enum.count(cards, &(&1.column == column))}
      end)

    %{
      generated_at: now(),
      columns: @columns,
      counts: counts,
      projects: Enum.map(projects, &public_project/1),
      cards: cards,
      errors: errors,
      capabilities: read_only_capabilities()
    }
  end

  # The projection advertises no write capability: every mutation lives in the
  # native tracker, so a client must not offer Taskboard edits.
  defp read_only_capabilities do
    %{
      create_issue: false,
      comment: false,
      dispatch: false,
      retry: false,
      rework: false,
      accept: false,
      pause: false,
      drag_and_drop: false
    }
  end

  @spec project_snapshot(String.t(), keyword()) :: result(map())
  def project_snapshot(project_id, opts \\ []) do
    settings = Keyword.get_lazy(opts, :settings, fn -> Config.settings!() end)

    with {:ok, project} <- find_project(project_id, settings, opts) do
      snapshot = project_snapshot_entry(project, opts)

      {:ok,
       %{
         generated_at: now(),
         columns: @columns,
         project: public_project(snapshot),
         cards: Map.get(snapshot, :cards, []),
         errors: if(snapshot[:error], do: [snapshot.error], else: [])
       }}
    end
  end

  def issue_detail(project_id, identifier, opts \\ [])

  @spec issue_detail(String.t(), String.t(), keyword()) :: result(map())
  def issue_detail(project_id, identifier, opts) when is_binary(project_id) and is_binary(identifier) do
    settings = Keyword.get_lazy(opts, :settings, fn -> Config.settings!() end)

    with {:ok, project} <- find_project(project_id, settings, opts),
         {:ok, detail} <- fetch_detail(project, identifier, opts) do
      detail = attach_local_execution(project, detail, identifier)

      card =
        if project.local do
          detail.issue
          |> card_payload(
            project,
            local_runtime_entry(detail.issue, opts),
            detail.execution,
            Map.get(detail, :deliveries, [])
          )
        else
          nil
        end

      {:ok,
       detail
       |> Map.put(:issue, issue_payload(detail.issue))
       |> Map.put(:project, public_project(project))
       |> Map.put(:card, card)
       |> Map.put(:capabilities, detail_capabilities(project, settings, detail))
       |> Map.put(:generated_at, now())}
    end
  end

  @doc """
  Reject Issue creation.

  The Taskboard is a read-only projection, so this entry point never mutates a
  tracker; creation happens in the native GitHub or GitLab Issue. The function
  stays exported with its original arity for a stable JSON route, and a caller
  always receives the retired-write error.
  """
  @spec create_issue(String.t(), map(), keyword()) :: result(map())
  def create_issue(_project_id, attrs, _opts \\ []) when is_map(attrs), do: {:error, :taskboard_read_only}

  @doc "Reject operator comments; the Taskboard publishes nothing to a tracker."
  @spec comment(String.t(), String.t(), String.t(), keyword()) :: result(map())
  def comment(project_id, identifier, _body, _opts \\ [])
      when is_binary(project_id) and is_binary(identifier),
      do: {:error, :taskboard_read_only}

  @doc """
  Reject every state-changing action.

  Dispatch, pause, retry, rework, and accept each move a native Issue. The
  Taskboard is a read-only projection, so it refuses the mutation and points
  operators at the native tracker instead.
  """
  @spec perform_action(String.t(), String.t(), String.t(), map(), keyword()) :: result(map())
  def perform_action(project_id, identifier, action, _attrs, _opts \\ [])
      when is_binary(project_id) and is_binary(identifier) and is_binary(action),
      do: {:error, :taskboard_read_only}

  @spec write_enabled?(map()) :: boolean()
  def write_enabled?(settings) do
    settings.taskboard.enabled and is_binary(settings.taskboard.control_token) and
      is_binary(settings.taskboard.provider_token)
  end

  @spec authorized?(map(), String.t() | nil) :: boolean()
  def authorized?(settings, token) do
    expected = settings.taskboard.control_token
    is_binary(expected) and is_binary(token) and Plug.Crypto.secure_compare(expected, token)
  end

  @spec runtime_status(map() | nil) :: String.t()
  def runtime_status(nil), do: "idle"
  def runtime_status(%{status: status}) when is_binary(status), do: status
  def runtime_status(_entry), do: "active"

  @spec card_payload(Issue.t(), map(), map() | nil, map() | nil, [map()]) :: map()
  def card_payload(%Issue{} = issue, project, runtime_entry, execution \\ nil, deliveries \\ []) do
    labels = Enum.map(issue.labels, &normalize_label/1)
    column = column_for(issue, labels, runtime_entry, lifecycle_accepted?(execution))
    status = agent_status(column, labels, runtime_entry, issue)
    artifacts = card_artifacts(execution, deliveries, project)

    %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      title: issue.title,
      summary: Provider.summary(issue.description),
      description: issue.description,
      priority: issue.priority || Provider.priority(labels),
      tracker_state: issue.state,
      labels: labels,
      url: issue.url,
      project_id: project.id,
      project: project.name,
      repo: project.repo,
      kind: project.kind,
      column: column,
      agent_status: status,
      needs_human: column == "Human Review",
      runtime: public_runtime(runtime_entry),
      delivery: delivery_hint(labels),
      artifacts: artifacts,
      human_action: human_action(column, labels, status, issue, artifacts, execution),
      updated_at: Provider.iso8601(issue.updated_at),
      created_at: Provider.iso8601(issue.created_at)
    }
  end

  defp project_entries(settings, opts) do
    local = local_project(settings)

    settings.taskboard.projects
    |> Enum.map(&remote_project/1)
    |> then(fn remote ->
      if Keyword.get(opts, :local_only, false) do
        [local]
      else
        [local | remote]
      end
    end)
  end

  defp local_project(settings) do
    provider = settings.tracker.provider || %{}
    repo = provider["repo"] || provider["project_path"] || settings.tracker.project_slug || "local"
    kind = settings.tracker.kind || "unknown"

    %{
      id: "#{kind}-#{slug(repo)}",
      name: repo,
      kind: kind,
      repo: repo,
      url: nil,
      local: true,
      token: nil,
      settings: settings
    }
  end

  defp remote_project(project) do
    %{
      id: project["id"],
      name: project["name"] || project["repo"] || project["id"],
      kind: project["kind"],
      repo: project["repo"],
      url: String.trim_trailing(project["url"], "/"),
      local: false,
      token: project["token"],
      settings: nil
    }
  end

  defp find_project(project_id, settings, opts) do
    case Enum.find(project_entries(settings, opts), &(&1.id == project_id)) do
      nil -> {:error, :taskboard_project_not_found}
      project -> {:ok, project}
    end
  end

  defp project_snapshot_entry(%{local: true} = project, opts) do
    with {:ok, provider} <- Provider.module_for(project.kind),
         {:ok, issues} <- provider.list_issues(project.settings.tracker, opts) do
      runtime = local_runtime_snapshot(opts)

      cards =
        issues
        |> assigned_to(project.settings.tracker)
        |> Enum.map(fn
          %Issue{} = issue ->
            card_payload(
              issue,
              project,
              runtime_entry(issue, runtime),
              local_execution(issue.id, issue.identifier),
              provider_delivery_summaries(provider, project.settings.tracker, issue, opts)
            )

          _ ->
            nil
        end)
        |> Enum.reject(&is_nil/1)
        |> sort_cards()

      project
      |> public_project()
      |> Map.put(:cards, cards)
      |> Map.put(:write_enabled, write_enabled?(project.settings))
    else
      error -> failed_project(project, error)
    end
  end

  defp project_snapshot_entry(%{local: false} = project, opts) do
    path = "/api/v1/taskboard/projects/#{Provider.encode(project.id)}"

    case remote_request(project, path, opts) do
      {:ok, payload} when is_map(payload) ->
        cards = Enum.map(payload["cards"] || [], &normalize_remote_card(&1, project))

        project
        |> public_project()
        |> Map.put(:cards, cards)
        |> Map.put(:write_enabled, is_binary(project.token))

      {:ok, _payload} ->
        failed_project(project, :invalid_remote_taskboard_payload)

      {:error, reason} ->
        failed_project(project, reason)
    end
  end

  defp assigned_to(issues, %{assignee: assignee})
       when is_binary(assignee) and assignee != "" do
    Enum.filter(issues, fn
      %Issue{assignee_id: ^assignee} -> true
      _ -> false
    end)
  end

  defp assigned_to(issues, _tracker), do: issues

  defp failed_project(project, reason) do
    project
    |> public_project()
    |> Map.put(:cards, [])
    |> Map.put(:error, format_error(reason))
    |> Map.put(:write_enabled, (project.local && write_enabled?(project.settings)) || is_binary(project.token))
  end

  defp public_project(project) do
    %{
      id: project.id,
      name: project.name,
      kind: project.kind,
      repo: project.repo,
      url: project.url,
      local: project.local,
      write_enabled: Map.get(project, :write_enabled, false)
    }
  end

  defp local_runtime_snapshot(opts) do
    fun =
      Keyword.get_lazy(opts, :runtime_snapshot_fun, fn ->
        fn -> Orchestrator.snapshot() end
      end)

    if is_function(fun, 0) do
      case fun.() do
        %{} = snapshot -> snapshot
        _ -> %{}
      end
    else
      %{}
    end
  end

  defp local_runtime_entry(issue, opts) do
    runtime_entry(issue, local_runtime_snapshot(opts))
  end

  defp runtime_entry(issue, runtime) do
    (Enum.map(List.wrap(runtime[:running]), &Map.put(&1, :status, "running")) ++
       Enum.map(List.wrap(runtime[:retrying]), &Map.put(&1, :status, "retrying")) ++
       Enum.map(List.wrap(runtime[:blocked]), &Map.put(&1, :status, "blocked")))
    |> Enum.find(fn entry ->
      entry[:issue_id] == issue.id or entry[:identifier] == issue.identifier or
        entry[:issue_identifier] == issue.identifier
    end)
  end

  defp provider_delivery_summaries(provider, settings, issue, opts) do
    if Code.ensure_loaded?(provider) and function_exported?(provider, :delivery_summaries, 3) do
      case provider.delivery_summaries(settings, issue, opts) do
        {:ok, deliveries} when is_list(deliveries) ->
          deliveries

        {:error, reason} ->
          Logger.warning("Taskboard delivery enrichment failed issue=#{issue.identifier || issue.id} reason=#{inspect(reason)}")

          []
      end
    else
      []
    end
  end

  # Migration off the retired label-as-acceptance rule. The Taskboard used to
  # fabricate acceptance from the current `symphony:accept` label plus native
  # closure, and the test suite asserted that forged behaviour. A label cannot
  # carry the version information an acceptance decision needs (design 16.2), so
  # no label selects a column. `Done` and `accepted` now require the versioned
  # lifecycle fact the member journal derives from the plan contract: the flow is
  # completed with its delivery accepted against the current manifest revision
  # and with no remaining restriction (`closeable`). A natively closed Issue
  # without that fact stays in Human Review as an unverified historical
  # conclusion instead of a business Done.
  defp lifecycle_accepted?(execution),
    do: is_map(execution) and Map.get(execution, :closeable) == true

  defp column_for(%Issue{} = issue, labels, runtime_entry, accepted?) do
    status = runtime_status(runtime_entry)

    cond do
      accepted? ->
        "Done"

      closed?(issue) or human_review?(labels, status) ->
        "Human Review"

      in_progress?(labels, status) ->
        "In Progress"

      true ->
        "Todo"
    end
  end

  defp closed?(%Issue{state: state}),
    do: normalize_label(state) in ["closed", "cancelled", "canceled", "done"]

  defp human_review?(labels, status) do
    status == "blocked" or
      Enum.any?(labels, &(&1 in ["symphony:review", "symphony:blocked", "symphony:failed"]))
  end

  defp in_progress?(labels, status) do
    status in ["running", "retrying"] or "symphony:running" in labels
  end

  defp agent_status("Done", _labels, _runtime, _issue), do: "accepted"

  defp agent_status("Human Review", labels, runtime_entry, issue) do
    cond do
      closed?(issue) -> "unverified closure"
      runtime_status(runtime_entry) == "blocked" -> "blocked"
      "symphony:failed" in labels -> "failed"
      "symphony:review" in labels -> "review"
      true -> "waiting for human"
    end
  end

  defp agent_status("In Progress", _labels, %{status: "retrying"}, _issue), do: "retrying"
  defp agent_status("In Progress", _labels, %{status: "running"}, _issue), do: "running"
  defp agent_status("In Progress", _labels, _runtime, _issue), do: "waiting to run"
  defp agent_status(_column, _labels, _runtime, _issue), do: "idle"

  defp public_runtime(nil), do: nil

  defp public_runtime(entry) do
    %{
      status: runtime_status(entry),
      issue_id: entry[:issue_id],
      session_id: entry[:session_id],
      turn_count: entry[:turn_count],
      last_event: entry[:last_event],
      last_message: entry[:last_message] || entry[:error],
      last_event_at: Provider.iso8601(entry[:last_event_at] || entry[:blocked_at]),
      due_at: entry[:due_at],
      attempt: entry[:attempt]
    }
  end

  defp delivery_hint(labels), do: if("symphony:review" in labels, do: "review pending")

  defp sort_cards(cards) do
    Enum.sort_by(cards, fn card ->
      {column_order(card.column), card.priority || 99, -timestamp(card.updated_at)}
    end)
  end

  defp column_order(column), do: Enum.find_index(@columns, &(&1 == column)) || 99

  defp timestamp(nil), do: 0

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :microsecond)
      _ -> 0
    end
  end

  defp fetch_detail(%{local: true} = project, identifier, opts) do
    with {:ok, provider} <- Provider.module_for(project.kind) do
      provider.issue_detail(project.settings.tracker, identifier, opts)
    end
  end

  defp fetch_detail(%{local: false} = project, identifier, opts) do
    path =
      "/api/v1/taskboard/issues/#{Provider.encode(project.id)}/#{Provider.encode(identifier)}"

    case remote_request(project, path, opts) do
      {:ok, payload} when is_map(payload) -> {:ok, normalize_remote_detail(payload)}
      {:ok, _payload} -> {:error, :invalid_remote_taskboard_payload}
      error -> error
    end
  end

  defp attach_local_execution(%{local: true} = _project, detail, identifier) do
    case local_execution(detail.issue.id, identifier) do
      nil -> detail
      execution -> Map.put(detail, :execution, execution)
    end
  end

  defp attach_local_execution(_project, detail, _identifier), do: detail

  defp normalize_remote_card(card, project) when is_map(card) do
    %{
      issue_id: card["issue_id"],
      issue_identifier: card["issue_identifier"],
      title: card["title"],
      summary: card["summary"],
      description: card["description"],
      priority: card["priority"],
      tracker_state: card["tracker_state"],
      labels: List.wrap(card["labels"]),
      url: card["url"],
      project_id: project.id,
      project: card["project"] || project.name,
      repo: card["repo"] || project.repo,
      kind: card["kind"] || project.kind,
      column: card["column"],
      agent_status: card["agent_status"],
      needs_human: card["needs_human"] == true,
      runtime: card["runtime"],
      delivery: card["delivery"],
      artifacts: List.wrap(card["artifacts"]),
      human_action: card["human_action"],
      updated_at: card["updated_at"],
      created_at: card["created_at"]
    }
  end

  defp normalize_remote_card(_card, project) do
    %{
      issue_id: nil,
      issue_identifier: nil,
      title: "Invalid remote card",
      summary: nil,
      description: nil,
      priority: nil,
      tracker_state: nil,
      labels: [],
      url: nil,
      project_id: project.id,
      project: project.name,
      repo: project.repo,
      kind: project.kind,
      column: "Todo",
      agent_status: "idle",
      needs_human: false,
      runtime: nil,
      delivery: nil,
      artifacts: [],
      human_action: nil,
      updated_at: nil,
      created_at: nil
    }
  end

  defp normalize_remote_detail(payload) when is_map(payload) do
    issue = payload["issue"] || payload["card"] || %{}
    project = payload["project"] || %{}

    %{
      issue: remote_issue(issue, payload),
      description: payload["description"] || issue["description"],
      labels: List.wrap(payload["labels"] || issue["labels"]),
      comments: Enum.map(List.wrap(payload["comments"]), &normalize_remote_comment/1),
      deliveries: List.wrap(payload["deliveries"]),
      execution: payload["execution"],
      capabilities: payload["capabilities"] || %{},
      project: %{
        id: project["id"],
        name: project["name"],
        kind: project["kind"],
        repo: project["repo"],
        url: project["url"],
        local: false,
        write_enabled: project["write_enabled"] == true
      }
    }
  end

  defp remote_issue(issue, payload) do
    %Issue{
      id: issue["issue_id"] || issue["id"] || issue["issue_identifier"],
      identifier: issue["issue_identifier"] || issue["identifier"],
      title: issue["title"],
      description: issue["description"] || payload["description"],
      priority: issue["priority"],
      state: issue["tracker_state"] || issue["state"],
      url: issue["url"],
      labels: List.wrap(issue["labels"] || payload["labels"])
    }
  end

  defp normalize_remote_comment(comment) when is_map(comment) do
    %{
      id: comment["id"],
      author: comment["author"],
      body: comment["body"],
      system: comment["system"] == true,
      engine: comment["engine"] == true,
      created_at: comment["created_at"],
      updated_at: comment["updated_at"],
      url: comment["url"]
    }
  end

  defp issue_payload(%Issue{} = issue) do
    %{
      id: issue.id,
      identifier: issue.identifier,
      title: issue.title,
      description: issue.description,
      priority: issue.priority,
      state: issue.state,
      branch_name: issue.branch_name,
      url: issue.url,
      labels: issue.labels,
      created_at: Provider.iso8601(issue.created_at),
      updated_at: Provider.iso8601(issue.updated_at)
    }
  end

  defp local_execution(identifier, fallback_identifier) do
    if Execution.enabled?() do
      [identifier, fallback_identifier, native_issue_id(identifier), native_issue_id(fallback_identifier)]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.find_value(&read_local_execution/1)
    end
  end

  defp read_local_execution(identifier) do
    case RunJournal.read(RunJournal.directory(Execution.journal_root(), identifier)) do
      {:ok, %{} = record} ->
        %{
          phase: record["phase"],
          attempt_id: record["attempt_id"],
          attempt_count: record["attempt_count"],
          thread_id: record["thread_id"],
          turn_id: record["turn_id"],
          blocker_reason: record["blocker_reason"],
          handoff: record["handoff"],
          workflow_state: get_in(record, ["workflow", "state"]),
          closeable: get_in(record, ["workflow", "closeable"]) == true,
          acceptance_mode: get_in(record, ["workflow", "contract", "acceptance_mode"]),
          manifest: get_in(record, ["workflow", "manifest"]),
          delivery: record["delivery"],
          intermediate: get_in(record, ["workflow", "intermediate"]),
          stage_results: record["stage_results"],
          updated_at: record["updated_at"],
          events: record["events"] |> List.wrap() |> Enum.take(-20)
        }

      _ ->
        nil
    end
  end

  defp native_issue_id(identifier) when is_binary(identifier) do
    case Regex.run(~r/^(?:GH|GL)-([1-9][0-9]*)$/, identifier) do
      [_, number] -> number
      _ -> nil
    end
  end

  defp card_artifacts(execution, deliveries, project) do
    execution = execution || %{}

    manifest_items =
      execution
      |> Map.get(:manifest)
      |> case do
        %{"items" => items} -> List.wrap(items)
        _ -> []
      end

    execution_artifacts =
      [execution[:delivery], execution[:intermediate] | manifest_items]
      |> Enum.filter(&is_map/1)
      |> Enum.map(&artifact_payload(&1, project))

    delivery_artifacts =
      deliveries
      |> Enum.filter(&is_map/1)
      |> Enum.map(&artifact_payload(&1, project))

    (execution_artifacts ++ delivery_artifacts)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.url)
  end

  defp artifact_payload(item, project) do
    kind = item["kind"] || item[:kind]
    url = item["url"] || item[:url]

    if kind in ["mr", "pr", "report"] and http_url?(url) do
      %{
        kind: kind,
        label: artifact_label(kind, url, project.kind),
        title: item["id"] || item["title"] || item[:id] || item[:title],
        url: url,
        state: item["state"] || item[:state]
      }
    end
  end

  defp artifact_label("report", _url, _tracker_kind), do: "Open report"

  defp artifact_label(kind, url, "github") when kind in ["mr", "pr"] do
    case Regex.run(~r{/pull/([1-9][0-9]*)}, url) do
      [_, number] -> "Open pull request ##{number}"
      _ -> "Open pull request"
    end
  end

  defp artifact_label(kind, url, _tracker_kind) when kind in ["mr", "pr"] do
    case Regex.run(~r{/merge_requests/([1-9][0-9]*)}, url) do
      [_, number] -> "Open merge request !#{number}"
      _ -> "Open merge request"
    end
  end

  defp http_url?(url) when is_binary(url), do: String.match?(url, ~r/^https?:\/\//i)
  defp http_url?(_url), do: false

  defp human_action("Human Review", _labels, status, issue, artifacts, execution) do
    acceptance_mode = execution[:acceptance_mode] || "separate"

    cond do
      closed?(issue) ->
        %{
          required: true,
          summary:
            "This Issue is closed without a lifecycle acceptance bound to its current contract. " <>
              "Symphony shows the historical conclusion as unverified and will not advance dependent work from it. " <>
              "Reopen the Issue or record a versioned decision.",
          label: nil,
          issue_url: issue.url
        }

      status == "failed" ->
        %{
          required: true,
          summary: "Open the Issue and record the next decision; the latest agent run failed.",
          label: "symphony:rework"
        }

      status == "blocked" ->
        %{
          required: true,
          summary: "Open the Issue and answer the blocker so execution can continue.",
          label: nil
        }

      artifacts != [] ->
        %{
          required: true,
          summary: artifact_action(artifacts, acceptance_mode),
          label: nil,
          issue_url: issue.url
        }

      true ->
        %{
          required: true,
          summary: "Open the Issue and read the latest handoff. Record the requested decision before continuing.",
          label: nil,
          issue_url: issue.url
        }
    end
  end

  defp human_action(_column, _labels, _status, _issue, _artifacts, _execution), do: nil

  defp artifact_action(artifacts, acceptance_mode) do
    reports = Enum.filter(artifacts, &(&1.kind == "report"))
    requests = Enum.filter(artifacts, &(&1.kind in ["mr", "pr"]))

    review =
      case {reports, requests} do
        {[], [request]} -> "Review #{artifact_name(request)}."
        {[], requests} -> "Review the linked requests: #{join_artifacts(requests)}."
        {reports, []} -> "Review #{join_artifacts(reports)}."
        {reports, requests} -> "Review #{join_artifacts(reports)} and #{join_artifacts(requests)}."
      end

    cond do
      requests == [] ->
        review <>
          " This task has no MR; that is expected for its delivery type. " <>
          "Record a decision bound to the current delivery when it meets the agreed criteria."

      acceptance_mode == "merge" ->
        review <> " Merge the request when approved; Symphony will verify that delivery."

      true ->
        review <>
          " Merge the request if approved, then record a decision bound to the current delivery."
    end
  end

  defp join_artifacts(artifacts), do: Enum.map_join(artifacts, " and ", &artifact_name/1)

  defp artifact_name(%{url: url, kind: kind}) do
    case Regex.run(~r{/(?:pull|merge_requests)/([1-9][0-9]*)}, url) do
      [_, number] when kind in ["mr", "pr"] ->
        if String.contains?(url, "/pull/"), do: "PR ##{number}", else: "MR !#{number}"

      _ ->
        if kind == "report", do: "the report", else: "the delivery"
    end
  end

  # The detail payload mirrors the read-only board and offers no write action.
  defp detail_capabilities(_project, _settings, _detail) do
    %{comment: false, dispatch: false, retry: false, rework: false, accept: false, pause: false}
  end

  defp remote_request(project, path, opts) do
    fun =
      Keyword.get(opts, :remote_request_fun, fn url, headers ->
        request_options = [
          headers: headers,
          connect_options: [timeout: @remote_timeout_ms],
          receive_timeout: @remote_timeout_ms
        ]

        Req.get(url, request_options)
      end)

    headers =
      case project.token do
        token when is_binary(token) -> [{"x-symphony-taskboard-token", token}]
        _ -> []
      end

    case fun.(project.url <> path, headers) do
      {:ok, %{status: status, body: payload}} when status in 200..299 -> {:ok, payload}
      {:ok, %{status: status, body: payload}} -> {:error, {:remote_taskboard_status, status, payload}}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_remote_taskboard_response}
    end
  rescue
    error -> {:error, {:taskboard_request_failed, Exception.message(error)}}
  end

  defp format_error({:remote_taskboard_status, status, %{"error" => %{"message" => message}}}),
    do: "HTTP #{status}: #{message}"

  defp format_error(reason), do: inspect(reason)

  defp normalize_label(label) when is_binary(label), do: label |> String.trim() |> String.downcase()
  defp normalize_label(_label), do: ""
  defp slug(value), do: value |> to_string() |> String.downcase() |> String.replace(~r/[^a-z0-9]+/u, "-") |> String.trim("-")
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
