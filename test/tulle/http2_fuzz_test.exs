defmodule Tulle.Http2FuzzTest do
  use ExUnit.Case, async: true
  import ExUnitProperties

  @moduletag :fuzzing

  require Bandit

  alias Tulle.Http
  alias Tulle.Http2.Client

  @port 8433

  property "fill_to_size" do
    check all(
            x <- StreamData.iodata(),
            n <- StreamData.positive_integer()
          ) do
      {res, res_rest} = Client.fill_to_size(x, n)

      x_len = IO.iodata_length(x)

      if x_len <= n do
        assert res_rest == {:rem, n - x_len}
        assert IO.iodata_to_binary(res) == IO.iodata_to_binary(x)
      else
        assert IO.iodata_to_binary([res, res_rest]) == IO.iodata_to_binary(x)
      end
    end
  end

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

    start_supervised!(
      {
        Bandit,
        plug: {__MODULE__.TestingPlug, planned_req},
        scheme: :https,
        port: @port,
        ip: :loopback,
        keyfile: key_file,
        certfile: cert_file,
        cipher_suite: :strong,
        startup_log: false,
        http_1_options: [enabled: false],
        http_2_options: [default_local_settings: [initial_window_size: 10]]
      },
      restart: :transient,
      id: Bandit
    )
  end

  defp start_client do
    start_supervised!(
      {Client,
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
    check all(planned_req <- request_response_gen()) do
      _bandit = start_server(planned_req)
      client = start_client()

      planned_req
      |> Task.async_stream(
        fn {req_id, req_resp} ->
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

      stop_supervised!(Client)
      stop_supervised!(Bandit)
    end
  end

  defp stream_request_response_gen do
    request_response_gen(StreamData.list_of(StreamData.iodata()))
  end

  @tag :integration
  @tag timeout: 120_000
  property "fuzz streaming requests against local server" do
    check all(planned_req <- stream_request_response_gen()) do
      _bandit = start_server(planned_req)
      client = start_client()

      planned_req
      |> Task.async_stream(
        fn {req_id, req_resp} ->
          collectable =
            Http.request_collectable!(client, {:get, "/", [{"req_id", req_id}]})

          {status, _headers, resp_body} =
            req_resp.req_body
            |> Enum.into(collectable)
            |> Http.close_request!()

          assert status == req_resp.status

          assert IO.iodata_to_binary(Enum.to_list(resp_body)) ==
                   IO.iodata_to_binary(req_resp.resp_body)
        end,
        max_concurrency: 50,
        ordered: false,
        timeout: :infinity
      )
      |> Stream.run()

      stop_supervised!(Client)
      stop_supervised!(Bandit)
    end
  end

  defp ca_files do
    key_file = Path.dirname(__ENV__.file) |> Path.join("cert/key.pem")
    cert_file = Path.dirname(__ENV__.file) |> Path.join("cert/cert.pem")
    {key_file, cert_file}
  end
end