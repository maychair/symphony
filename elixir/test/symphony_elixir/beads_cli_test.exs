defmodule SymphonyElixir.BeadsCLITest do
  use SymphonyElixir.TestSupport
  alias Mix.Tasks.Beads.{Accept, Resume}
  alias SymphonyElixir.Beads.{Adapter, RunJournal}

  setup do
    root = Path.dirname(Workflow.workflow_file_path())
    database = Path.join(root, ".beads")
    File.mkdir_p!(database)
    bd = Path.join(root, "bd")
    data = Path.join(root, "issue.json")
    issue = %{"id" => "bd-cli", "title" => "CLI", "status" => "blocked", "assignee" => "symphony-cli", "labels" => ["enabled", "human"]}
    File.write!(data, Jason.encode!(issue))

    File.write!(bd, """
    #!/usr/bin/env python3
    import sys,json
    args=sys.argv[4:]
    with open(#{inspect(data)}) as f: issue=json.load(f)
    if args[0]=='update':
      def val(k): return args[args.index(k)+1]
      if issue['status']!=val('--if-status') or issue['assignee']!=val('--if-assignee'): sys.exit(13)
      issue['status']=val('--status')
      if '--remove-label' in args and val('--remove-label') in issue['labels']: issue['labels'].remove(val('--remove-label'))
      for i,a in enumerate(args):
        if a=='--set-metadata':
          k,v=args[i+1].split('=',1); issue.setdefault('metadata',{})[k]=v
      with open(#{inspect(data)},'w') as f: json.dump(issue,f)
    print(json.dumps([issue]))
    """)

    File.chmod!(bd, 0o755)

    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker:
      kind: beads
      required_labels: [enabled]
      provider:
        bin: #{Jason.encode!(bd)}
        beads_dir: #{Jason.encode!(database)}
        review_repository: github.com/example/repo
    workspace:
      root: #{Jason.encode!(Path.join(root, "workspaces"))}
      retain: true
    ---
    {{ issue.description }}
    """)

    :ok = WorkflowStore.force_reload()
    workspace = Path.join(root, "workspaces/bd-cli")
    File.mkdir_p!(workspace)
    {:ok, record} = RunJournal.admit(Adapter.journal_root(Config.settings!().tracker), "bd-cli")

    {:ok, record} =
      RunJournal.checkpoint(record, %{
        "owner" => "symphony-cli",
        "thread_id" => "cli-thread",
        "turn_id" => "cli-turn",
        "workspace" => workspace,
        "beads_dir" => database,
        "delivery" => %{"review_url" => "https://github.com/example/repo/pull/1", "head_sha" => String.duplicate("a", 40)}
      })

    :ok = RunJournal.complete(record, "awaiting_human")
    {:ok, root: root, record: record, data: data}
  end

  test "accept CLI rejects invalid flags and missing evidence, then accepts verified delivery", context do
    assert_raise Mix.Error, fn -> Accept.run([]) end
    base = ["--workflow", Workflow.workflow_file_path(), "--issue", "bd-cli", "--accepted-by", "Human", "--review-url"]
    assert_raise Mix.Error, fn -> Accept.run(base ++ ["https://github.com/other/repo/pull/1"]) end
    gh = Path.join(context.root, "gh")

    File.write!(gh, """
    #!/bin/sh
    printf '%s\\n' '{"state":"MERGED","mergedAt":"2026-10-14T00:00:00Z","mergeCommit":{"oid":"merged"},"headRefOid":"#{String.duplicate("a", 40)}","url":"https://github.com/example/repo/pull/1"}'
    """)

    File.chmod!(gh, 0o755)
    old_path = System.get_env("PATH")
    on_exit(fn -> restore_env("PATH", old_path) end)
    System.put_env("PATH", context.root <> ":" <> old_path)
    assert :ok = Accept.run(base ++ ["https://github.com/example/repo/pull/1"])
    assert Jason.decode!(File.read!(context.data))["status"] == "closed"
  end

  test "resume CLI requires stopped executor and reconciles observed idle terminal turn", context do
    assert_raise Mix.Error, fn -> Resume.run([]) end
    args = ["--workflow", Workflow.workflow_file_path(), "--issue", "bd-cli", "--executor-stopped"]
    assert_raise Mix.Error, fn -> Resume.run(args) end
    codex = Path.join(context.root, "codex")

    File.write!(codex, """
    #!/bin/sh
    count=0
    while IFS= read -r line; do
      count=$((count+1))
      case "$count" in
        1) printf '%s\\n' '{"id":1,"result":{}}' ;;
        2) ;;
        3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"cli-thread","status":{"type":"idle"},"turns":[{"id":"cli-turn","status":"completed"}]}}}' ;;
      esac
    done
    """)

    File.chmod!(codex, 0o755)
    text = String.replace(File.read!(Workflow.workflow_file_path()), "workspace:", "codex:\n  command: #{Jason.encode!(codex)}\nworkspace:")
    File.write!(Workflow.workflow_file_path(), text)
    :ok = WorkflowStore.force_reload()
    {:ok, record} = RunJournal.read(context.record["directory"])
    {:ok, _} = RunJournal.checkpoint(record, %{"executor_os_pid" => "99999999"})
    assert :ok = Resume.run(args)
    assert Jason.decode!(File.read!(context.data))["status"] == "in_progress"
  end
end
