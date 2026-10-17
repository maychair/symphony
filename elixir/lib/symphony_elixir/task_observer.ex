defmodule SymphonyElixir.TaskObserver do
  @moduledoc "One owner-linked, bounded native fact reader. Only the owning session applies its results."
  use GenServer
  alias SymphonyElixir.{Config, TaskExecution}

  @spec start_link(map(), map(), keyword()) :: GenServer.on_start()
  def start_link(record, executions, opts) do
    interval = Keyword.get_lazy(opts, :observation_interval_ms, fn -> Config.settings!().polling.interval_ms end)
    timeout = Keyword.get(opts, :observation_timeout_ms, 60_000)

    if is_integer(interval) and interval > 0 and is_integer(timeout) and timeout > 0,
      do: GenServer.start_link(__MODULE__, {self(), record, executions, opts, interval, timeout}),
      else: {:error, :invalid_observation_timing}
  end

  @spec take(pid()) :: :pending | {:ok, map()} | {:error, term()}
  def take(observer), do: GenServer.call(observer, :take)

  @spec activate(pid()) :: :ok | {:error, term()}
  def activate(observer), do: GenServer.call(observer, :activate)

  @spec stop(pid()) :: :ok | {:error, term()}
  def stop(observer), do: GenServer.call(observer, :stop)

  @impl true
  def init({owner, record, executions, opts, interval, timeout}) do
    Process.flag(:trap_exit, true)
    context = %{owner: owner, record: record, executions: executions, opts: opts}
    runtime = %{active: false, task: nil, timer: nil, started: nil, result: :pending}
    {:ok, context |> Map.merge(runtime) |> Map.merge(%{interval: interval, timeout: timeout})}
  end

  @impl true
  def handle_call(_, {caller, _}, %{owner: owner} = state) when caller != owner,
    do: {:reply, {:error, :observation_not_owned}, state}

  def handle_call(:stop, _, state), do: {:stop, :normal, :ok, state}

  def handle_call(:activate, _, %{active: false} = state) do
    send(self(), :observe)
    {:reply, :ok, %{state | active: true}}
  end

  def handle_call(:activate, _, state), do: {:reply, {:error, :observation_already_active}, state}
  def handle_call(:take, _, %{result: :pending} = state), do: {:reply, :pending, state}

  def handle_call(:take, _, state) do
    Process.send_after(self(), :observe, state.interval)
    result = if match?({:ok, _}, state.result) and System.monotonic_time(:millisecond) - state.started > state.timeout, do: {:error, :observation_expired}, else: state.result
    {:reply, result, %{state | result: :pending}}
  end

  @impl true
  def handle_info(:observe, %{active: true, task: nil, result: :pending} = state) do
    task = Task.async(fn -> TaskExecution.observe_running(state.record, state.executions, state.opts) end)
    timer = Process.send_after(self(), {:timeout, task.ref}, state.timeout)
    {:noreply, %{state | task: task, timer: timer, started: System.monotonic_time(:millisecond)}}
  end

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    Process.cancel_timer(state.timer)
    {:noreply, %{state | task: nil, timer: nil, result: result}}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{task: %Task{ref: ref}} = state) do
    Process.cancel_timer(state.timer)
    {:noreply, %{state | task: nil, timer: nil, result: {:error, {:observation_process_failed, reason}}}}
  end

  def handle_info({:timeout, ref}, %{task: %Task{ref: ref} = task} = state) do
    Task.shutdown(task, :brutal_kill)
    {:noreply, %{state | task: nil, timer: nil, result: {:error, :observation_timeout}}}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, %{task: task}) do
    if task, do: Task.shutdown(task, :brutal_kill)
    :ok
  end
end
