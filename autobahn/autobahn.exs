defmodule Tulle.Autobahn do
  alias Tulle.Websocket

  defmodule TestHandler do
    use GenServer
    require Logger

    @impl GenServer
    def init(_) do
      {:ok, nil}
    end

    @impl GenServer
    def handle_cast({:text, ws, msg}, _) do
      spawn(fn ->
        _ = Websocket.send(ws, :text, msg)
      end)

      {:noreply, nil}
    end

    def handle_cast({:binary, ws, msg}, _) do
      spawn(fn ->
        _ = Websocket.send(ws, :binary, msg)
      end)

      {:noreply, nil}
    end

    def handle_cast({:closed, ws, _close_code}, _) do
      spawn(fn ->
        GenServer.stop(ws)
      end)

      {:noreply, nil}
    end

    def handle_cast({:warning, _ws, reason}, _) do
      spawn(fn ->
        Logger.warning(inspect({:handle_warning, reason}))
      end)

      {:noreply, nil}
    end
  end

  def run(from, to) do
    Logger.put_module_level(Tulle.Websocket, :info)
    {:ok, handler} = GenServer.start_link(__MODULE__.TestHandler, nil)

    Task.async_stream(
      from..to,
      fn i ->
        {_pid, ref} =
          spawn_monitor(fn -> run_case(handler, i) end)

        receive do
          {:DOWN, ^ref, _, _, _} ->
            nil
            # after
            #   0 -> nil
        end
      end,
      timeout: 300_000
      #   max_concurrency: 1
    )
    |> Stream.run()

    {:ok, ws} = Websocket.start_link(handler, [])

    Process.sleep(2_000)

    :ok = Websocket.connect(ws, "http://127.0.0.1:9001/updateReports?agent=tulle", [])
  end

  defp run_case(handler, i) do
    {:ok, ws} = Websocket.start_link(handler, [])

    Websocket.connect(ws, "http://127.0.0.1:9001/runCase?case=#{i}&agent=tulle", [])
    |> case do
      :ok ->
        ref = Process.monitor(ws)

        receive do
          {:DOWN, ^ref, _, _, _} -> nil
        end

      _ ->
        nil
    end
  end
end
