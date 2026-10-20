defmodule SymphonyElixir.ReviewJournalTest do
  use ExUnit.Case
  alias SymphonyElixir.ReviewLane.{Journal, Owner}

  @moduletag :tmp_dir

  test "kernel exclusion, durable readback and explicit release bind the actual BEAM", %{tmp_dir: root} do
    assert {:ok, journal, nil} = Journal.open(root)
    assert receipt(root)["process"]["pid"] == System.pid()
    assert receipt(root)["released"] == false
    assert {:error, "review_journal_locked"} = Journal.open(root)
    assert :ok = Journal.write!(journal, "{\"schema_version\":2}")
    assert :ok = Journal.check(journal)
    copied = Task.async(fn -> {Journal.check(journal), Journal.close(journal)} end)
    assert {{:error, :review_journal_not_owned}, :ok} = Task.await(copied)
    assert :ok = Journal.check(journal)
    assert :ok = Journal.close(journal)
    assert receipt(root)["released"] == true
    assert {:ok, next, "{\"schema_version\":2}"} = Journal.open(root)
    assert :ok = Journal.close(next)
    assert :ok = Journal.close(next)
    assert :ok = Journal.close(nil)
    assert {:error, :review_journal_not_owned} = Journal.check(nil)
    assert_raise RuntimeError, ~r/persistence failed/, fn -> Journal.write!(journal, "stale") end
    assert File.read!(Path.join(root, "review-lane.json")) == "{\"schema_version\":2}"
  end

  test "dead local controller permits recovery without asserting native execution stopped", %{tmp_dir: root} do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        {:ok, journal, nil} = Journal.open(root)
        :ok = Journal.write!(journal, "unknown native execution")
        send(parent, {:owned, self()})
        receive do: (:hold -> :ok)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    assert_receive {:owned, ^pid}, 2_000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    assert {:ok, next, "unknown native execution"} = await_unlocked(root)
    assert :ok = Journal.close(next)
  end

  test "broker loss cannot transfer ownership while its controller remains alive", %{tmp_dir: root} do
    {:ok, journal, nil} = Journal.open(root)
    :ok = Journal.write!(journal, "before crash")
    Port.close(journal.port)
    assert {:error, :previous_review_controller_not_stopped} = await_unlocked(root)
    assert receipt(root)["released"] == false
    assert {:error, :review_journal_not_owned} = Journal.check(journal)
    assert File.read!(Path.join(root, "review-lane.json")) == "before crash"
  end

  test "another OS controller must exit before its unreleased journal can be acquired", %{tmp_dir: root} do
    script = Path.join(root, "controller.py")
    broker = Path.expand("../../priv/review_journal.py", __DIR__)

    File.write!(script, """
    import json,os,struct,subprocess,sys
    def read(stream):
      n=struct.unpack('!I',stream.read(4))[0]
      return json.loads(stream.read(n))
    def write(stream,value):
      data=json.dumps(value).encode();stream.write(struct.pack('!I',len(data))+data);stream.flush()
    child=subprocess.Popen([sys.executable,'-u',sys.argv[1],sys.argv[2],str(os.getpid())],stdin=subprocess.PIPE,stdout=subprocess.PIPE)
    assert 'ok' in read(child.stdout)
    write(child.stdin,{'op':'claim','listener':{'token':'1'*32,'vm':'0'*32,'pid':'<0.1.0>'}})
    assert read(child.stdout)=={'ok':True}
    write(child.stdin,{'op':'write','body':'foreign native execution remains unknown'})
    assert read(child.stdout)=={'ok':True}
    write(sys.stdout.buffer,{'ready':str(os.getpid())})
    assert read(sys.stdin.buffer)=={'op':'exit'}
    child.stdin.close();child.wait(timeout=5)
    """)

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(System.find_executable("python3"))},
        [:binary, :exit_status, {:packet, 4}, args: ["-u", script, broker, root]]
      )

    assert_receive {^port, {:data, ready}}, 2_000
    pid = Jason.decode!(ready)["ready"]
    assert receipt(root)["process"]["pid"] == pid
    assert pid != System.pid()
    assert {:error, "review_journal_locked"} = Journal.open(root)
    Port.command(port, Jason.encode!(%{"op" => "exit"}))
    assert_receive {^port, {:exit_status, 0}}, 2_000
    assert {:ok, journal, "foreign native execution remains unknown"} = await_unlocked(root)
    assert :ok = Journal.close(journal)
  end

  test "foreign machine, boot, namespace or live process cannot prove predecessor exit", %{tmp_dir: root} do
    {:ok, journal, nil} = Journal.open(root)
    :ok = Journal.close(journal)
    original = %{receipt(root) | "released" => false, "listener" => Map.put(journal.listener, "vm", String.duplicate("0", 32))}

    for owner <- [original | Enum.map(~w(machine boot namespace), &put_in(original["process"][&1], "foreign"))] do
      write_receipt(root, owner)
      assert {:error, :previous_review_controller_not_stopped} = Journal.open(root)
      assert receipt(root) == owner
    end

    # An existing PID with a different start time is a different OS process.
    write_receipt(root, put_in(original["process"]["start"], "0"))
    assert {:ok, next, nil} = Journal.open(root)
    :ok = Journal.close(next)
    write_receipt(root, put_in(original["process"]["pid"], "9999999999999999999"))
    assert {:ok, next, nil} = Journal.open(root)
    :ok = Journal.close(next)
  end

  test "corrupt ownership and a legacy unowned journal require explicit recovery", %{tmp_dir: root} do
    {:ok, journal, nil} = Journal.open(root)
    :ok = Journal.close(journal)
    original = receipt(root)

    for owner <- [
          %{},
          [],
          Map.put(original, "released", nil),
          Map.put(original, "listener", %{}),
          put_in(original["process"]["pid"], "bad"),
          put_in(original["process"]["boot"], ""),
          Map.put(original, "process", %{})
        ] do
      write_receipt(root, owner)
      assert {:error, :invalid_review_journal_owner} = Journal.open(root)
      assert receipt(root) == owner
    end

    File.write!(Path.join(root, "review-journal-owner.json"), "invalid json")
    assert {:error, reason} = Journal.open(root)
    assert reason =~ "Expecting value"
    File.rm!(Path.join(root, "review-journal-owner.json"))
    File.write!(Path.join(root, "review-lane.json"), "legacy")
    assert {:error, "review_journal_owner_missing_migration_required"} = Journal.open(root)
    assert File.read!(Path.join(root, "review-lane.json")) == "legacy"
  end

  test "replacing the permanent lock path fences both the old writer and a contender", %{tmp_dir: root} do
    {:ok, journal, nil} = Journal.open(root)
    :ok = Journal.write!(journal, "before replacement")
    lock = Path.join(root, "review-journal.lock")
    File.rename!(lock, lock <> ".old")
    File.write!(lock, "")
    assert {:error, :previous_review_controller_not_stopped} = Journal.open(root)
    assert {:error, "review_journal_lock_replaced"} = Journal.check(journal)
    assert_raise RuntimeError, ~r/persistence failed/, fn -> Journal.write!(journal, "overwrite") end
    assert File.read!(Path.join(root, "review-lane.json")) == "before replacement"
  end

  test "failed durable replacement loses transport and never releases the live controller", %{tmp_dir: root} do
    {:ok, journal, nil} = Journal.open(root)
    File.mkdir!(Path.join(root, "review-lane.json"))
    assert_raise RuntimeError, ~r/persistence failed/, fn -> Journal.write!(journal, "cannot replace directory") end
    assert {:error, :previous_review_controller_not_stopped} = await_unlocked(root)
    refute receipt(root)["released"]
    assert :ok = Journal.close(journal)
  end

  test "a same VM ticket for a living process does not authorize replacement", %{tmp_dir: root} do
    {:ok, journal, nil} = Journal.open(root)
    :ok = Journal.close(journal)
    write_receipt(root, %{receipt(root) | "listener" => Owner.new(self()), "released" => false})
    assert {:error, :previous_review_controller_not_stopped} = Journal.open(root)
  end

  test "missing runtime and an unusable directory fail before claiming ownership", %{tmp_dir: root} do
    file = Path.join(root, "file")
    File.write!(file, "existing")
    assert {:error, :enotdir} = Journal.open(file)
    path = System.get_env("PATH")

    try do
      System.put_env("PATH", root)
      assert {:error, :review_journal_python_unavailable} = Journal.open(root)
    after
      System.put_env("PATH", path)
    end

    refute File.exists?(Path.join(root, "review-journal-owner.json"))
  end

  test "malformed, lost and stalled protocol responses cannot leave a reusable channel" do
    for {script, expected} <- [
          {"data=b'invalid';sys.stdout.buffer.write(struct.pack('!I',len(data))+data);sys.stdout.buffer.flush();sys.stdin.buffer.read()", :invalid_review_journal_response},
          {"sys.exit(7)", {:review_journal_exit, 7}},
          {"sys.stdin.buffer.read()", :review_journal_timeout}
        ] do
      code = "import sys,struct; n=struct.unpack('!I',sys.stdin.buffer.read(4))[0];sys.stdin.buffer.read(n);" <> script

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(System.find_executable("python3"))},
          [:binary, :exit_status, {:packet, 4}, args: ["-u", "-c", code]]
        )

      assert {:error, ^expected} = Journal.check(%{port: port})
      assert {:error, :review_journal_not_owned} = Journal.check(%{port: port})
    end

    assert {:error, :review_journal_transport_closed} = Journal.check(%{port: 42})
  end

  defp receipt(root), do: Jason.decode!(File.read!(Path.join(root, "review-journal-owner.json")))
  defp write_receipt(root, value), do: File.write!(Path.join(root, "review-journal-owner.json"), Jason.encode!(value))

  defp await_unlocked(root, attempts \\ 100) do
    case Journal.open(root) do
      {:error, "review_journal_locked"} when attempts > 0 ->
        Process.sleep(10)
        await_unlocked(root, attempts - 1)

      result ->
        result
    end
  end
end
