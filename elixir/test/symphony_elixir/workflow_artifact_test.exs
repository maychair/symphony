defmodule SymphonyElixir.WorkflowArtifactTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.WorkflowArtifact

  test "artifact transport uses arguments, private input and no shell interpolation" do
    root = Path.join(System.tmp_dir!(), "workflow-tool-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    script = Path.join(root, "tool with spaces.py")
    marker = Path.join(root, "unexpected")

    File.write!(script, """
    import json,os,sys,pathlib,stat
    p=pathlib.Path(sys.argv[-1]);assert sys.argv[-2]=='--input'
    assert stat.S_IMODE(p.parent.stat().st_mode)==0o700
    payload=json.loads(p.read_text())
    print(json.dumps({'input':str(p),'payload':payload,'argument':sys.argv[1]}))
    """)

    argument = "$(touch #{marker})"
    config = %{"result_command" => [System.find_executable("python3"), script, argument]}
    assert {:ok, result} = WorkflowArtifact.evaluate(config, %{"value" => "private content"})
    assert result["payload"] == %{"value" => "private content"}
    assert result["argument"] == argument
    refute File.exists?(result["input"])
    refute File.exists?(marker)
  end

  test "missing, failed and malformed validators fail closed" do
    assert {:error, :workflow_result_command_required} = WorkflowArtifact.evaluate(%{}, %{})

    for program <- ["print('not json')", "print('[]')", "raise SystemExit(2)", "print('x'*1048577)"] do
      command = [System.find_executable("python3"), "-c", program]
      assert {:error, _} = WorkflowArtifact.evaluate(%{"result_command" => command}, %{})
    end

    assert {:error, _} = WorkflowArtifact.evaluate(%{"result_command" => ["missing-workflow-tool-1337"]}, %{})
    assert {:error, :workflow_artifact_unavailable} = WorkflowArtifact.evaluate(%{"result_command" => ["python3"]}, %{"unserializable" => self()})
  end
end
