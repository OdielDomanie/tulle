defmodule Tulle.Http1PoolFuzzTest do
  use ExUnit.Case, async: true
  import ExUnitProperties

  @moduletag :fuzzing

  require Bandit

  alias Tulle.Http
  alias Tulle.Http1

  @port 8434

  defmodule TestingPlug do
    import Plug.Conn

    def init(requests) do
      requests
    end

    def call(conn, requests) do
      {:ok, req_body, conn} = read_body(conn)
      [req_id] = get_req_header(conn, "req_id")
      planned_req = requests[req_id]

      case planned_req.req_body do
        nil ->
          assert req_body in [nil, ""]

        _ ->
          assert IO.iodata_to_binary(req_body) ==
                   IO.iodata_to_binary(planned_req.req_body)
      end

      Process.sleep(planned_req.delay)
      send_resp(conn, planned_req.status, planned_req.resp_body)
    end
  end

  defp request_response_gen(req_body_gen) do
    single_req_resp =
      gen all(
            req_body <- req_body_gen,
            req_body == nil || IO.iodata_length(req_body) < 8_000_000,
            resp_body <- StreamData.iodata(),
            IO.iodata_length(resp_body) < 8_000_000,
            status <- StreamData.integer(200..200),
            delay <- StreamData.integer(0..10)
          ) do
        %{req_body: req_body, resp_body: resp_body, status: status, delay: delay}
      end

    key_gen =
      StreamData.repeatedly(fn -> System.unique_integer([:positive]) |> to_string() end)

    StreamData.map_of(key_gen, single_req_resp)
  end

  defp request_response_gen do
    request_response_gen(StreamData.one_of([nil, StreamData.iodata()]))
  end

  defp start_server(planned_req) do
    {key_file, cert_file} = ca_files()

    Bandit.start_link(
      plug: {__MODULE__.TestingPlug, planned_req},
      scheme: :https,
      port: @port,
      ip: :loopback,
      keyfile: key_file,
      certfile: cert_file,
      cipher_suite: :strong,
      # startup_log: false,
      http_1_options: [enabled: false],
      http_2_options: [default_local_settings: [initial_window_size: 10]]
    )
    |> elem(1)
  end

  defp start_pool do
    {:ok, sv} = DynamicSupervisor.start_link([])

    start_supervised!(
      {Http1.Pool,
       sv: sv,
       address: "127.0.0.1",
       port: @port,
       connect_opts: [
         transport_opts: [
           verify: :verify_none
         ]
       ]},
      restart: :temporary
    )
  end

  @tag :integration
  @tag timeout: 120_000
  property "fuzz req body, resp body, status against local server" do
    task_sv = start_link_supervised!(Task.Supervisor)

    check all(planned_req <- request_response_gen()) do
      bandit = start_server(planned_req)
      pool = start_pool()

      Task.Supervisor.async_stream(
        task_sv,
        planned_req,
        fn {req_id, req_resp} ->
          client = Http1.Pool.check_out!(pool)

          {status, _headers, resp_body} =
            Http.request!(
              client,
              {:get, "/", [{"req_id", req_id}]},
              req_resp.req_body
            )

          assert status == req_resp.status

          assert IO.iodata_to_binary(Enum.to_list(resp_body)) ==
                   IO.iodata_to_binary(req_resp.resp_body)
        end,
        max_concurrency: 50,
        ordered: false,
        timeout: :infinity
      )
      |> Stream.run()

      stop_supervised!(Http1.Pool)
      Process.exit(bandit, :normal)
      Process.monitor(bandit)

      receive do
        {:DOWN, _, _, ^bandit, _} -> :ok
      end
    end
  end

  defp stream_request_response_gen do
    request_response_gen(StreamData.list_of(StreamData.iodata()))
  end

  @tag :integration
  @tag timeout: 120_000
  property "fuzz streaming requests against local server" do
    task_sv = start_link_supervised!(Task.Supervisor)

    check all(planned_req <- stream_request_response_gen()) do
      bandit = start_server(planned_req)
      pool = start_pool()

      results =
        for {req_id, req_resp} <- planned_req do
          fn ->
            client = Http1.Pool.check_out!(pool)

            collectable =
              Http.request_collectable!(client, {:get, "/", [{"req_id", req_id}]})

            {status, _headers, resp_body} =
              req_resp.req_body
              |> Enum.into(collectable)
              |> Http.close_request!()

            assert status == req_resp.status

            assert IO.iodata_to_binary(Enum.to_list(resp_body)) ==
                     IO.iodata_to_binary(req_resp.resp_body)
          end
        end
        |> Enum.map(&Task.Supervisor.async_nolink(task_sv, &1))
        |> Task.yield_many(on_timeout: :kill_task)

      stop_supervised!(Http1.Pool)
      Process.unlink(bandit)
      Process.exit(bandit, :shutdown)
      Process.monitor(bandit)

      receive do
        {:DOWN, _, _, ^bandit, _} -> :ok
      end

      assert Enum.all?(results, fn {_, res} -> match?({:ok, _}, res) end)
    end
  end

  defp ca_files do
    key_file = Path.dirname(__ENV__.file) |> Path.join("cert/key.pem")
    cert_file = Path.dirname(__ENV__.file) |> Path.join("cert/cert.pem")
    {key_file, cert_file}
  end
end
