defmodule Tulle.Http1PoolFuzzTest do
  use ExUnit.Case, async: true
  import ExUnitProperties
  require Logger
  require Bandit

  alias Tulle.Http
  alias Tulle.Http1

  @moduletag :fuzzing
  # @moduletag capture_log: true

  @port 8434

  # Must increase open file descriptor limit!
  # 10_000 seems OK

  setup_all do
    table = :ets.new(__MODULE__.ReqTable, [:public])
    {key_file, cert_file} = ca_files()

    start_supervised!({
      Bandit,
      startup_log: false,
      plug: {__MODULE__.TestingPlug, table},
      scheme: :https,
      port: @port,
      ip: :loopback,
      keyfile: key_file,
      certfile: cert_file,
      cipher_suite: :strong,
      http_2_options: [default_local_settings: [initial_window_size: 10]]
    })

    %{planned_req_table: table}
  end

  defmodule TestingPlug do
    import Plug.Conn

    def init(table) do
      table
    end

    def call(conn, table) do
      {:ok, req_body, conn} = read_body(conn)
      [req_id] = get_req_header(conn, "req_id")
      [{_, planned_req}] = :ets.lookup(table, req_id)

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
            delay <- StreamData.integer(0..30)
          ) do
        %{req_body: req_body, resp_body: resp_body, status: status, delay: delay}
      end

    key_gen =
      StreamData.repeatedly(fn -> System.unique_integer([:positive]) |> to_string() end)

    StreamData.map_of(key_gen, single_req_resp, max_length: 200)
  end

  defp request_response_gen do
    request_response_gen(StreamData.one_of([nil, StreamData.iodata()]))
  end

  defp start_pool do
    {:ok, sv} = DynamicSupervisor.start_link([])

    start_supervised!(
      {Http1.Pool,
       sv: fn -> sv end,
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
  property "fuzz req body, resp body, status against local server", context do
    task_sv = start_link_supervised!(Task.Supervisor)

    check all(planned_req <- request_response_gen()) do
      :ets.delete_all_objects(context.planned_req_table)
      :ets.insert(context.planned_req_table, Enum.to_list(planned_req))
      pool = start_pool()

      results =
        for {req_id, req_resp} <- planned_req do
          fn ->
            Process.sleep(req_resp.delay)
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

            Http1.Pool.check_in(pool, client)
          end
        end
        |> Enum.map(&Task.Supervisor.async_nolink(task_sv, &1))
        |> Task.yield_many(on_timeout: :kill_task)

      assert map_size(planned_req) >= (:sys.get_state(pool)[:workers] |> map_size) - 1
      # Logger.debug(
      #   count_req: map_size(planned_req),
      #   open_conns: :sys.get_state(pool)[:workers] |> map_size
      # )

      stop_supervised!(Http1.Pool)

      assert Enum.all?(results, fn {_, res} -> match?({:ok, _}, res) end)
    end
  end

  defp stream_request_response_gen do
    request_response_gen(StreamData.list_of(StreamData.iodata(), max_length: 20))
  end

  @tag :integration
  @tag timeout: 120_000
  property "fuzz streaming requests against local server", context do
    task_sv = start_link_supervised!(Task.Supervisor)

    check all(planned_req <- stream_request_response_gen()) do
      :ets.delete_all_objects(context.planned_req_table)
      :ets.insert(context.planned_req_table, Enum.to_list(planned_req))

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

            Http1.Pool.check_in(pool, client)
          end
        end
        |> Enum.map(&Task.Supervisor.async_nolink(task_sv, &1))
        |> Task.yield_many(on_timeout: :kill_task)

      assert map_size(planned_req) >= (:sys.get_state(pool)[:workers] |> map_size) - 1

      stop_supervised!(Http1.Pool)

      assert Enum.all?(results, fn {_, res} -> match?({:ok, _}, res) end)
    end
  end

  defp ca_files do
    key_file = Path.dirname(__ENV__.file) |> Path.join("cert/key.pem")
    cert_file = Path.dirname(__ENV__.file) |> Path.join("cert/cert.pem")
    {key_file, cert_file}
  end
end
