defmodule Tulle.HttpTest do
  use ExUnit.Case, async: true

  defmodule TestingPlug do
    import Plug.Conn

    def init(planned_reqs) do
      planned_reqs
    end

    # The header {"req_id", req_id} must be present in the request
    def call(conn, planned_reqs) do
      {:ok, req_body, conn} = read_body(conn)
      [req_id] = get_req_header(conn, "req_id")
      planned_req = planned_reqs[req_id]

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

  @type planned_reqs :: %{(req_id :: planned_req) => iodata() | nil}
  @type planned_req :: %{
          req_body: iodata() | nil,
          delay: timeout(),
          status: 200..599,
          resp_body: iodata()
        }
  @spec start_server(planned_reqs()) :: {:ok, pid}
  def start_server(planned_req) do
    start_supervised(
      {Bandit,
       plug: {__MODULE__.TestingPlug, planned_req},
       scheme: :http,
       port: 8080,
       ip: :loopback,
       startup_log: false,
       http_2_options: [default_local_settings: [initial_window_size: 10]]}
    )
  end

  defp start_client(http_ver) do
    start_supervised(
      {Module.concat([Tulle, http_ver, Client]), scheme: :http, address: "127.0.0.1", port: 8080}
    )
  end

  defp assert_status(client, status, "Http1") do
    assert status == :sys.get_state(client)[:status]
  end

  defp assert_status(_client, _status, "Http2") do
    true
  end

  for http_ver <- ["Http1", "Http2"] do
    describe http_ver do
      @http_ver http_ver
      alias Tulle.Http

      test "client connect-disconnect" do
        {:ok, _server} = start_server(%{})

        {:ok, client} = start_client(@http_ver)
        assert_status(client, :idle, @http_ver)
      end

      test "send empty request, receive empty and and non empty" do
        ref1 = "1"

        req1 = %{
          req_body: nil,
          delay: 0,
          status: 204,
          resp_body: ""
        }

        ref2 = "2"
        req2 = %{req1 | resp_body: "testy response", status: 200}
        {:ok, _server} = start_server(%{ref1 => req1, ref2 => req2})

        {:ok, client} = start_client(@http_ver)

        assert_status(client, :idle, @http_ver)
        headers1 = [{"req_id", ref1}]
        {status1, _, iodata_stream1} = Http.request!(client, {:get, "/", headers1}, nil)
        assert status1 == 204
        assert "" == iodata_stream1 |> Enum.to_list() |> IO.iodata_to_binary()

        assert_status(client, :idle, @http_ver)
        headers2 = [{"req_id", ref2}]
        {status2, _, iodata_stream2} = Http.request!(client, {:get, "/", headers2}, nil)
        assert status2 == 200
        assert "testy response" == iodata_stream2 |> Enum.to_list() |> IO.iodata_to_binary()
      end

      test "send non empty request, receive non empty" do
        ref1 = "1"

        req1 = %{
          req_body: "testy req",
          delay: 0,
          status: 200,
          resp_body: "testy response"
        }

        ref2 = "2"
        req2 = %{req1 | resp_body: "testy response2"}

        {:ok, _server} = start_server(%{ref1 => req1, ref2 => req2})

        {:ok, client} = start_client(@http_ver)

        assert_status(client, :idle, @http_ver)
        headers1 = [{"req_id", ref1}]
        {status1, _, iodata_stream1} = Http.request!(client, {:get, "/", headers1}, req1.req_body)
        assert status1 == 200
        assert "testy response" == iodata_stream1 |> Enum.to_list() |> IO.iodata_to_binary()

        assert_status(client, :idle, @http_ver)
        headers2 = [{"req_id", ref2}]
        {status2, _, iodata_stream2} = Http.request!(client, {:get, "/", headers2}, req2.req_body)
        assert status2 == 200
        assert "testy response2" == iodata_stream2 |> Enum.to_list() |> IO.iodata_to_binary()
      end

      test "stream request with Collectible" do
        ref1 = "1"

        req1 = %{
          req_body: "testy req",
          delay: 0,
          status: 200,
          resp_body: "testy response"
        }

        ref2 = "2"
        req2 = %{req1 | req_body: "testy req2", resp_body: "testy response2"}

        {:ok, _server} = start_server(%{ref1 => req1, ref2 => req2})

        {:ok, client} = start_client(@http_ver)

        assert_status(client, :idle, @http_ver)

        headers1 = [{"req_id", ref1}]
        request1 = Http.request_collectable!(client, {:get, "/foopath", headers1})
        assert_status(client, :sending, @http_ver)

        {status1, _, iodata_stream1} =
          req1.req_body
          |> :binary.bin_to_list()
          |> Enum.map(fn e -> <<e>> end)
          |> Enum.into(request1)
          |> Http.close_request!()

        assert status1 == 200
        assert "testy response" == iodata_stream1 |> Enum.to_list() |> IO.iodata_to_binary()

        assert_status(client, :idle, @http_ver)
        headers2 = [{"req_id", ref2}]
        request2 = Http.request_collectable!(client, {:get, "/", headers2})

        {status2, _, iodata_stream2} =
          req2.req_body
          |> :binary.bin_to_list()
          |> Enum.map(fn e -> <<e>> end)
          |> Enum.into(request2)
          |> Http.close_request!()

        assert status2 == 200
        assert "testy response2" == iodata_stream2 |> Enum.to_list() |> IO.iodata_to_binary()
      end
    end
  end
end
