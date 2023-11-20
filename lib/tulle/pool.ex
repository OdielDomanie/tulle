# defmodule Tulle.Pool do
#   @moduledoc """
#   Pool used for Http1.
#   """

#   use GenServer

#   import Map

#   @worker_idle_max 60_000

#   @type t :: GenServer.name()
#   @type worker :: pid

#   @spec get_worker(t, (worker -> result)) :: result when result: any
#   @doc """
#   Do work in the pool.

#   A worker is checked-out if available.
#   If non available, a new one is created.
#   """
#   def get_worker(pool, work) do
#     case GenServer.call(pool, :get_worker) do
#       {:available, worker} ->
#         try do
#           work.(worker)
#         after
#           check_in(pool, worker)
#         end

#       {:new, worker, worker_initer} ->
#         try do
#           with {:ok, worker} <- worker_initer.(worker) do
#             work.(worker)
#           end
#         after
#           check_in(pool, worker)
#         end
#     end
#   end

#   @spec check_in(t, worker) :: :ok
#   defp check_in(pool, worker), do: GenServer.cast(pool, {:check_in, worker})

#   def start_link({worker_child_spec, dyn_sv, opts}) do
#     GenServer.start_link(__MODULE__, {worker_child_spec, dyn_sv}, opts)
#   end

#   @impl GenServer
#   def init({worker_child_spec, dyn_sv}) do
#     {:ok,
#      %{
#        wcs: worker_child_spec,
#        sv: dyn_sv,
#        stop_seq: true,
#        workers: [],
#        idle_timers: MapSet.new()
#      }, {:continue, :start_first}}
#   end

#   @impl GenServer
#   def handle_continue(:start_first, state) do
#     [:ok, child | _] = DynamicSupervisor.start_child(state.sv, state.wcs) |> Tuple.to_list()

#     Process.monitor(child)
#     timer = Process.send_after(self(), @worker_idle_max, :worker_idle_timeout)
#     state = %{state | workers: [child], idle_timers: MapSet.put(state.idle_timers, timer)}

#     {:noreply, state}
#   end

#   @impl GenServer
#   def handle_info(
#         :worker_idle_timeour,
#         %{workers: [worker | workers_rest]} = state
#       ) do
#     case state.stop_seq do
#       true ->
#         DynamicSupervisor.terminate_child(state.sv, worker)
#         {:noreply, %{state | workers: workers_rest, idle_timers: timers_rest, stop_seq: false}}
#         false

#       false ->
#         timer = Process.send_after(self(), @worker_idle_max, :worker_idle_timeout)
#         {:noreply, %{state | idle_timers: [timer | timers_rest], stop_seq: true}}
#     end
#   end
# end
