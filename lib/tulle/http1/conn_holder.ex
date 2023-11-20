defmodule Tulle.Http1.Client do
  @moduledoc false

  use GenServer

  require Logger
  alias Mint.HTTP1

  @type t :: GenServer.name()

  def start_link(opts) do
    GenServer.start_link(__MODULE__, {opts[:scheme], opts[:address], opts[:port]}, opts)
  end

  @spec request!(t, String.t() | atom(), String.t(), Mint.Types.headers(), iodata() | nil) ::
          reference()
  def request!(client, method, path, headers, body) do
    method = to_string(method)
    GenServer.call(client, {:request, method, path, headers, body})
  end

  @spec request_stream!(t, String.t() | atom(), String.t(), Mint.Types.headers()) ::
          reference()
  def request_stream!(client, method, path, headers) do
    method = to_string(method)
    GenServer.call(client, {:request_stream, method, path, headers})
  end

  @spec send_chunk!(t, reference(), iodata()) :: :ok
  def send_chunk!(client, ref, data) do
    GenServer.call(client, {:send_chunk, ref, data})
  end

  @spec send_eof!(t, reference()) :: :ok
  def send_eof!(client, ref) do
    GenServer.call(client, {:send_chunk, ref, nil})
  end

  @impl true
  def init({scheme, address, port}) do
    {:ok, conn} =
      HTTP1.connect(scheme, address, port, transport_opts: [cacerts: :public_key.cacerts_get()])

    {
      :ok,
      %{conn: conn, req_ref: nil, req_caller: nil, status: :idle}
    }
  end

  @impl true
  def handle_call({:request, m, p, h, b}, from, %{status: :idle} = state) when b != :request do
    {:ok, conn, ref} = HTTP1.request(state.conn, m, p, h, b)
    {sender, _} = from
    state = %{state | conn: conn, req_ref: ref, req_caller: sender, status: :sent}
    {:reply, ref, state}
  end

  @impl true
  def handle_call({:request_stream, m, p, h}, from, %{status: :idle} = state) do
    {:ok, conn, ref} = HTTP1.request(state.conn, m, p, h, :stream)
    {sender, _} = from
    state = %{state | conn: conn, req_ref: ref, req_caller: sender, status: :sending}
    {:reply, ref, state}
  end

  @impl true
  def handle_call({:send_chunk, ref, :eof}, _from, %{status: :sending, req_ref: ref} = state) do
    {:ok, conn} = HTTP1.stream_request_body(state.conn, state.req_ref, :eof)

    state = %{state | conn: conn, status: :sent}
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:send_chunk, ref, data}, _from, %{status: :sending, req_ref: ref} = state) do
    {:ok, conn} = HTTP1.stream_request_body(state.conn, state.req_ref, data)

    state = %{state | conn: conn}
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(msg, %{status: :sent} = state) do
    case HTTP1.stream(state.conn, msg) do
      #
      {:ok, conn, resps} ->
        Enum.map(
          resps,
          fn resp ->
            send(state.req_caller, {state.req_ref, resp})
          end
        )

        done = Enum.find(resps, &match?({:done, _}, &1))

        state =
          case done do
            :done -> %{state | conn: conn, status: :idle}
            nil -> %{state | conn: conn}
          end

        {:noreply, state}

      #
      {:error, conn, err, resps} ->
        Enum.map(resps, &send(state.req_caller, &1))
        send(state.req_caller, {:error, err})
        state = %{state | conn: conn}
        {:noreply, state}
    end
  end
end
