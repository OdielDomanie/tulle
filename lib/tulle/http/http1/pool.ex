defmodule Tulle.HTTP1.Pool do
  @worker_idle_min 60_000

  @moduledoc """
  Pool for holding `Tulle.HTTP1.Client` processes.

  In current implementation,
  at least one connection (one process) is kept open.
  Idle processes are shutdown with a half-life of
  #{@worker_idle_min |> div(1_000)} seconds.
  """

  use GenServer

  require Logger
  alias Tulle.HTTP1

  @type pool :: GenServer.server()
  @type worker :: pid

  def start_link(opts) do
    connect_args =
      Enum.filter(opts, fn {k, _} -> k in [:scheme, :address, :port, :connect_opts] end)

    GenServer.start_link(__MODULE__, {opts[:sv], connect_args}, opts)
  end

  @spec check_out!(pool, timeout()) :: worker()
  @doc """
  Check-out a `Tulle.HTTP1.Client` process from the pool,
  spawning if necessary.
  """
  def check_out!(pool, timeout \\ 5000) do
    {:ok, client} = GenServer.call(pool, :check_out, timeout)
    client
  end

  @spec check_in(pool, worker()) :: :ok
  @doc """
  Returns a checked-out `Tulle.HTTP1.Client` back to the pool.
  """
  def check_in(pool, client) do
    GenServer.call(pool, {:check_in, client})
  end

  @impl true
  def init({sv, connect_args}) do
    state = %{
      seq: false,
      sv: sv,
      connect_args: connect_args
    }

    {:ok, state, {:continue, :init}}
  end

  @impl true
  def handle_continue(:init, state) do
    {:ok, first_worker, timer} = spawn_http1_worker(state.sv, state.connect_args)

    state = Map.put(state, :workers, %{first_worker => timer})
    {:noreply, state}
  end

  def handle_continue(:spawn_if_low, %{workers: workers} = state) when map_size(workers) >= 1 do
    {:noreply, state}
  end

  def handle_continue(:spawn_if_low, %{workers: workers} = state) when map_size(workers) < 1 do
    case spawn_http1_worker(state.sv, state.connect_args) do
      {:ok, worker, timer} ->
        workers = Map.put(workers, worker, timer)
        state = %{state | workers: workers}
        {:noreply, state}

      other ->
        Logger.warning(cant_spawn_worker: other)
        {:noreply, state}
    end
  end

  defp spawn_http1_worker(sv, connect_args) do
    spec =
      Supervisor.child_spec(
        {HTTP1.Client, connect_args},
        restart: :temporary
      )

    with {:ok, worker} <- DynamicSupervisor.start_child(sv.(), spec) do
      timer = set_timer(worker)
      Process.monitor(worker)
      {:ok, worker, timer}
    end
  end

  defp set_timer(worker) do
    Process.send_after(self(), {:timer, worker}, @worker_idle_min)
  end

  @impl true
  def handle_call(:check_out, _from, %{workers: workers} = state) when map_size(workers) > 0 do
    [{worker, timer}] = Enum.take(workers, 1)
    workers = Map.delete(workers, worker)
    Process.cancel_timer(timer, async: true, info: false)
    state = %{state | workers: workers}

    {:reply, {:ok, worker}, state, {:continue, :spawn_if_low}}
  end

  @impl true
  def handle_call(:check_out, _from, %{workers: workers} = state) when map_size(workers) == 0 do
    case spawn_http1_worker(state.sv, state.connect_args) do
      {:ok, new_worker, _new_timer} ->
        {:reply, {:ok, new_worker}, state, {:continue, :spawn_if_low}}

      error ->
        {:reply, {:error, error}, state}
    end
  end

  @impl true
  def handle_call({:check_in, worker}, from, state) do
    GenServer.reply(from, :ok)

    timer = set_timer(worker)
    workers = Map.put(state.workers, worker, timer)
    state = %{state | workers: workers}
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, proc, _reason}, %{workers: workers} = state)
      when is_map_key(workers, proc) do
    {timer, workers} = Map.pop!(workers, proc)
    Process.cancel_timer(timer, async: true, info: false)

    state = %{state | workers: workers}
    {:noreply, state, {:continue, :spawn_if_low}}
  end

  def handle_info({:DOWN, _ref, :process, proc, _reason}, %{workers: workers} = state)
      when not is_map_key(workers, proc) do
    {:noreply, state, {:continue, :spawn_if_low}}
  end

  def handle_info({:timer, worker}, %{workers: workers} = state)
      when is_map_key(workers, worker) do
    {_timer, workers} = Map.pop!(workers, worker)

    workers =
      if map_size(workers) > 0 and state.seq do
        Process.exit(worker, :shutdown)
        workers
      else
        timer = set_timer(worker)
        Map.put(workers, worker, timer)
      end

    # Only stop the processes 1/2 of the time
    # to smooth out the exits.
    seq = not state.seq

    state = %{state | workers: workers, seq: seq}
    {:noreply, state, {:continue, :spawn_if_low}}
  end

  def handle_info({:timer, worker}, %{workers: workers} = state)
      when not is_map_key(workers, worker) do
    {:noreply, state}
  end
end
