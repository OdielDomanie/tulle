defmodule Tulle.Autobahn do
  alias Tulle.Websocket

  defmodule TestHandler do
    # use GenServer
    require Logger

    alias Tulle.Websocket

    use Websocket

    def start_link({url_headers_extension, opts}) do
      Websocket.start_link(__MODULE__, nil, url_headers_extension, opts)
    end

    @impl WebSock
    def init(_) do
      {:ok, nil}
    end

    @impl WebSock
    def handle_in({msg, [opcode: type]}, state) do
      {:push, {type, msg}, state}
    end

    @impl WebSock
    def terminate(_reason, _state) do
      nil
    end

    @impl WebSock
    def handle_info(_term, state) do
      {:ok, state}
    end
  end

  def run(from, to) do
    Logger.put_module_level(Tulle.Websocket, :info)

    Task.async_stream(
      from..to,
      fn i ->
        {_pid, ref} =
          spawn_monitor(fn -> run_case(i) end)

        receive do
          {:DOWN, ^ref, _, _, _} ->
            nil
        end
      end,
      timeout: 300_000,
      max_concurrency: 3
    )
    |> Stream.run()

    Process.sleep(2_000)

    {:ok, ws} =
      TestHandler.start_link({[url: "http://127.0.0.1:9001/updateReports?agent=tulle"], []})
  end

  defp run_case(i) do
    {:ok, ws} =
      TestHandler.start_link({[url: "http://127.0.0.1:9001/runCase?case=#{i}&agent=tulle"], []})

    ref = Process.monitor(ws)

    receive do
      {:DOWN, ^ref, _, _, _} -> nil
    end
  end
end
