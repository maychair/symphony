defmodule SymphonyElixir.WorkflowSessionTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.{WorkflowInstructions, WorkflowSession}

  defmodule Backend do
    def start_session(root, [{:resume_thread_id, _} | _] = opts) do
      if Process.get(:workflow_mode) == :unconfirmed do
        {:error, :transport_unavailable}
      else
        opts[:on_thread_observed].(%{turn_id: nil})
        {:ok, %{thread_id: "thread", workspace: root}}
      end
    end

    def start_session(root, opts) do
      send(self(), {:session_options, opts})

      with :ok <- opts[:on_thread_intent].(), :ok <- opts[:on_thread_started].("thread") do
        {:ok, %{thread_id: "thread", workspace: root}}
      end
    end

    def run_turn(_session, prompt, _issue, opts) do
      send(self(), {:prompt, prompt})

      with :ok <- opts[:before_turn].() do
        opts[:on_message].(%{event: :session_started, turn_id: "turn"})

        case Process.get(:workflow_mode) do
          :missing ->
            {:ok, %{}}

          :crash ->
            raise "backend crashed"

          :failed_turn ->
            WorkflowSession.execute_agent_tool("workflow_submit", %{"result" => %{"answer" => "untrusted"}}, [])
            {:error, :turn_failed}

          _ ->
            WorkflowSession.execute_agent_tool("workflow_submit", %{"result" => %{"answer" => "done"}}, [])
            {:ok, %{}}
        end
      end
    end

    def confirm_session(_), do: if(Process.get(:workflow_mode) == :unconfirmed, do: {:error, :still_active}, else: :ok)
    def stop_session(_), do: send(self(), :transport_closed)
  end

  defp context do
    %{repository: "/fixture", prompt: "supplied instructions", issue: %{}, secret_environment_names: ["PRIVATE_TOKEN"], agent_environment: %{}}
  end

  defp run(
         checkpoint \\ fn change ->
           send(self(), {:checkpoint, change})
           :ok
         end
       ),
       do: WorkflowSession.run(context(), backend: Backend, checkpoint: checkpoint)

  test "one ordinary native session executes supplied instructions with no review-only reader" do
    assert {:ok, %{"answer" => "done"}, runtime} = run()
    assert runtime["thread_id"] == "thread" and runtime["turn_id"] == "turn"
    assert runtime["native_stop_confirmed"]
    assert_received {:prompt, "supplied instructions"}
    assert_received {:session_options, opts}
    refute Keyword.has_key?(opts, :review_only)
    assert [%{"name" => "workflow_submit"}] = opts[:dynamic_tool_binding].tool_specs
    assert opts[:dynamic_tool_binding].secret_environment_names == ["PRIVATE_TOKEN"]
    assert_received {:checkpoint, %{"thread_allocation_intent" => true}}
    assert_received {:checkpoint, %{"turn_allocation_intent" => true}}
    assert_received :transport_closed
    assert %{"success" => false} = WorkflowSession.execute_agent_tool("workflow_submit", %{"result" => %{}}, [])
  end

  test "missing artifact, failed turn, crash and unconfirmed stop cannot complete" do
    for mode <- [:missing, :failed_turn, :crash, :unconfirmed] do
      Process.put(:workflow_mode, mode)
      assert {:error, _, runtime} = run()
      assert runtime["thread_id"] == "thread"
      assert runtime["native_stop_confirmed"] == (mode != :unconfirmed)
      assert_received :transport_closed
    end
  end

  test "cancellation before allocation creates no native identity" do
    send(self(), :symphony_stop)
    assert {:error, _, runtime} = run()
    refute runtime["thread_id"]
    assert runtime["native_stop_confirmed"]
    refute_received {:checkpoint, _}
  end

  test "checkpoint refusal before allocation retains uncertainty and never starts a turn" do
    assert {:error, _, runtime} = run(fn _ -> {:error, :journal_unavailable} end)
    assert runtime["thread_allocation_intent"]
    refute runtime["native_stop_confirmed"]
    refute_received {:prompt, _}
  end

  test "turn checkpoint refusal stops the native session and cannot produce success" do
    assert {:error, _, runtime} =
             run(fn
               %{"turn_allocation_intent" => true} -> {:error, :fenced}
               _ -> :ok
             end)

    assert runtime["native_stop_confirmed"]
    assert_received :transport_closed
  end

  test "lost startup callback receipt reconciles only the observed thread" do
    for mode <- [:complete, :unconfirmed] do
      Process.put(:workflow_mode, mode)

      assert {:error, _, runtime} =
               run(fn
                 %{"thread_id" => _} -> {:error, :journal_failed}
                 _ -> :ok
               end)

      assert runtime["thread_id"] == "thread"
      assert runtime["native_stop_confirmed"] == (mode == :complete)
      refute_received {:prompt, _}
    end
  end

  test "lost turn checkpoint stops the session; malformed tool input is refused" do
    assert {:error, _, runtime} =
             run(fn
               %{"turn_id" => _} -> {:error, :journal_failed}
               _ -> :ok
             end)

    assert runtime["native_stop_confirmed"]
    assert %{"success" => false} = WorkflowSession.execute_agent_tool("other", %{}, [])
    assert %{"success" => false} = WorkflowSession.execute_agent_tool("workflow_submit", %{"result" => nil}, [])
  end

  test "generic instruction loading preserves content and detects a changed playbook" do
    root = Path.join(System.tmp_dir!(), "workflow-instructions-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    workflow = Path.join(root, "workflow.md")
    playbook = Path.join(root, "playbook.md")
    File.write!(workflow, "# Any workflow\nDo work")
    File.write!(playbook, "# Any playbook\nHow to work")
    config = %{"instruction_files" => [workflow, playbook]}
    assert {:ok, content, digest} = WorkflowInstructions.load(config)
    assert content == "Source: #{workflow}\n\n" <> File.read!(workflow) <> "\n\nSource: #{playbook}\n\n" <> File.read!(playbook)
    File.write!(playbook, "Changed method")
    assert {:ok, _, next} = WorkflowInstructions.load(config)
    refute next == digest

    for value <- [nil, [], ["relative"], [root], [Path.join(root, "missing")], [12]] do
      assert {:error, :workflow_instructions_unavailable} = WorkflowInstructions.load(%{"instruction_files" => value})
    end

    File.write!(playbook, " ")
    assert {:error, :workflow_instructions_unavailable} = WorkflowInstructions.load(config)
  end
end
