defmodule Tulle.HTTP2.Client do
  @moduledoc """
  HTTP2 Client. Used with `Tulle.HTTP`.
  """
  use GenServer

  import Map
  require Logger

  alias Mint.HTTP2
  import Mint.HTTP, only: [is_connection_message: 2]

  @type http2_client :: GenServer.server()

  def start_link(opts) do
    GenServer.start_link(
      __MODULE__,
      {opts[:scheme], opts[:address], opts[:port], opts[:connect_opts]},
      opts
    )
  end

  defp default_connect_opts(:https) do
    [
      transport_opts: [
        cacerts: :public_key.cacerts_get(),
        versions: [:"tlsv1.2", :"tlsv1.3"],
        timeout: 10_000
      ],
      client_settings: [
        enable_push: false
      ]
    ]
  end

  defp default_connect_opts(:http) do
    [
      transport_opts: [
        timeout: 10_000
      ],
      client_settings: [
        enable_push: false
      ]
    ]
  end

  @impl true
  @doc false
  def init({scheme, address, port, connect_opts}) do
    connect_opts =
      DeepMerge.deep_merge(default_connect_opts(scheme || :https), connect_opts || [])

    case Mint.HTTP2.connect(
           scheme || :https,
           address,
           port || 443,
           connect_opts
         ) do
      {:ok, conn} ->
        {:ok,
         %{
           address: address,
           conn: conn,
           requests: %{},
           window_waiting: [],
           connect_opts: connect_opts,
           port: port || 443,
           scheme: scheme || :https
         }}

      {:error, error} ->
        {:stop, error}
    end
  end

  @impl true
  @doc false
  def handle_call(:protocol, _from, state), do: {:reply, :http2, state}

  def handle_call(
        {:request, return_to, {method, path, headers}, body},
        from,
        %{conn: conn, requests: requests} = state
      ) do
    {:ok, conn} = open_if_closed(conn, state)

    if body_fits_window?(conn, body) do
      case HTTP2.request(conn, method, path, headers, body) do
        {:ok, conn, ref} ->
          requests = put(requests, ref, {return_to, nil})
          {:reply, {:ok, ref}, %{state | conn: conn, requests: requests}}

        {:error, conn, error} ->
          {:reply, {:error, error}, %{state | conn: conn}}
      end
    else
      case HTTP2.request(conn, method, path, headers, :stream) do
        {:ok, conn, ref} ->
          send(self(), {:chunk, ref, body, :eof_when_empty})
          requests = put(requests, ref, {return_to, from})
          {:noreply, %{state | conn: conn, requests: requests}}

        {:error, conn, error} ->
          {:reply, {:error, error}, %{state | conn: conn}}
      end
    end
  end

  def handle_call(
        {:request_stream, return_to, {method, path, headers}},
        _from,
        %{conn: conn, requests: requests} = state
      ) do
    {:ok, conn} = open_if_closed(conn, state)

    case HTTP2.request(conn, method, path, headers, :stream) do
      {:ok, conn, ref} ->
        requests = put(requests, ref, {return_to, nil})
        {:reply, {:ok, ref}, %{state | conn: conn, requests: requests}}

      {:error, conn, error} ->
        {:reply, {:error, error}, %{state | conn: conn}}
    end
  end

  def handle_call(
        {:chunk, ref, :cancel},
        _from,
        %{conn: conn, requests: requests} = state
      )
      when is_map_key(requests, ref) do
    case HTTP2.cancel_request(conn, ref) do
      {:ok, conn} ->
        requests = delete(requests, ref)
        {:reply, :ok, %{state | conn: conn, requests: requests}}

      {:error, conn, error} ->
        requests = delete(requests, ref)
        {:reply, {:error, error}, %{state | conn: conn, requests: requests}}
    end
  end

  def handle_call(
        {:chunk, _ref, :cancel},
        _from,
        state
      ) do
    {:reply, :ok, state}
  end

  def handle_call(
        {:chunk, ref, data},
        from,
        %{requests: requests} = state
      )
      when is_map_key(requests, ref) do
    send(self(), {:chunk, ref, data})
    requests = update!(requests, ref, fn {return_to, _} -> {return_to, from} end)
    {:noreply, %{state | requests: requests}}
  end

  @impl true
  @dialyzer {:no_opaque, handle_info: 2}
  def handle_info(
        msg,
        %{conn: conn, requests: requests, window_waiting: window_waiting} = state
      )
      when is_connection_message(conn, msg) do
    # Maybe the window size increased
    for chunk_msg <- Enum.reverse(window_waiting) do
      send(self(), chunk_msg)
    end

    state = %{state | window_waiting: []}

    case HTTP2.stream(conn, msg) do
      {:ok, conn, resps} ->
        requests = send_responses(requests, resps)
        {:noreply, %{state | conn: conn, requests: requests}}

      {:error, conn, reason, resps} ->
        requests = send_responses(requests, resps)
        requests = send_errors(requests, reason)
        {:noreply, %{state | conn: conn, requests: requests}}
    end
  end

  def handle_info(
        {:chunk, ref, chunk, :eof_when_empty},
        %{conn: conn, requests: requests, window_waiting: window_waiting} = state
      )
      when is_map_key(requests, ref) do
    window = max_window_size(conn, ref)
    {_, from} = requests[ref]

    if window == 0 do
      # Server should refill the window size, try again later.
      window_waiting = [{:chunk, ref, chunk, :eof_when_empty} | window_waiting]

      {:noreply, %{state | conn: conn, requests: requests, window_waiting: window_waiting}}
    else
      with {:done, conn} <- send_request_chunk(conn, ref, chunk, window),
           {:done, conn} <- send_request_chunk(conn, ref, :eof, window) do
        GenServer.reply(from, {:ok, ref})
        {:noreply, %{state | conn: conn}}
      else
        {:partial, conn, rest} ->
          send(self(), {:chunk, ref, rest, :eof_when_empty})
          {:noreply, %{state | conn: conn}}

        {:error, conn, reason} ->
          GenServer.reply(from, {:error, reason})
          requests = delete(requests, ref)
          {:noreply, %{state | conn: conn, requests: requests}}
      end
    end
  end

  def handle_info(
        {:chunk, ref, chunk},
        %{conn: conn, requests: requests, window_waiting: window_waiting} = state
      )
      when is_map_key(requests, ref) do
    window = max_window_size(conn, ref)
    {_, from} = requests[ref]

    if window <= 0 do
      # Server should refill the window size, try again later.
      window_waiting = [{:chunk, ref, chunk} | window_waiting]

      {:noreply, %{state | conn: conn, window_waiting: window_waiting}}
    else
      send_request_chunk(conn, ref, chunk, window)
      |> case do
        {:done, conn} ->
          GenServer.reply(from, :ok)
          {:noreply, %{state | conn: conn}}

        {:partial, conn, rest} ->
          send(self(), {:chunk, ref, rest})
          {:noreply, %{state | conn: conn}}

        {:error, conn, reason} ->
          GenServer.reply(from, {:error, reason})
          requests = delete(requests, ref)
          {:noreply, %{state | conn: conn, requests: requests}}
      end
    end
  end

  defp send_request_chunk(conn, ref, :eof, _) do
    case HTTP2.stream_request_body(conn, ref, :eof) do
      {:ok, conn} ->
        {:done, conn}

      {:error, _conn, _reason} = error ->
        error
    end
  end

  defp send_request_chunk(conn, ref, chunk, window) do
    case fill_to_size(chunk, window) do
      {chunk0, {:rem, rem}} when rem >= 0 ->
        case HTTP2.stream_request_body(conn, ref, chunk0) do
          {:ok, conn} -> {:done, conn}
          {:error, _conn, _reason} = error -> error
        end

      {chunk0, chunk_rest} ->
        case HTTP2.stream_request_body(conn, ref, chunk0) do
          {:ok, conn} -> {:partial, conn, chunk_rest}
          {:error, _conn, _reason} = error -> error
        end
    end
  end

  @doc false
  def send_responses(requests, []), do: requests

  def send_responses(requests, [resp | resps]) do
    case resp do
      {type, ref, _} when type in [:status, :headers, :data] ->
        {send_to, _} = requests[ref]
        send(send_to, resp)
        send_responses(requests, resps)

      {:done, ref} ->
        {{send_to, _}, requests} = Map.pop!(requests, ref)
        send(send_to, resp)
        send_responses(requests, resps)

      {:error, ref, _reason} ->
        {{send_to, _}, requests} = Map.pop!(requests, ref)
        send(send_to, resp)
        send_responses(requests, resps)
    end
  end

  @doc false
  def send_errors(requests, reason) do
    for {ref, {send_to, _}} <- requests do
      resp = {:error, ref, reason}
      send(send_to, resp)
    end

    %{}
  end

  defp open_if_closed(conn, state) do
    if HTTP2.open?(conn) do
      {:ok, conn}
    else
      # It might be still open for reading only. Just close it.
      HTTP2.close(conn)
      HTTP2.connect(state.scheme, state.address, state.port, state.connect_opts)
    end
  end

  defp max_window_size(conn) do
    min(
      HTTP2.get_server_setting(conn, :initial_window_size),
      HTTP2.get_window_size(conn, :connection)
    )
  end

  defp max_window_size(conn, ref) do
    min(
      HTTP2.get_window_size(conn, {:request, ref}),
      HTTP2.get_window_size(conn, :connection)
    )
  end

  defp body_fits_window?(_conn, nil), do: true

  defp body_fits_window?(conn, body) do
    IO.iodata_length(body) <= max_window_size(conn)
  end

  @spec fill_to_size(iodata(), pos_integer()) ::
          {iodata(), iodata() | {:rem, non_neg_integer()}}
  @doc false
  def fill_to_size(data, window)

  def fill_to_size(a, window) when is_integer(a) and a in 0..255 and 1 <= window do
    {a, {:rem, window - 1}}
  end

  def fill_to_size(a, window) when is_integer(a) and a in 0..255 and window == 0 do
    {"", a}
  end

  def fill_to_size(a, window) when is_binary(a) and byte_size(a) <= window do
    {a, {:rem, window - byte_size(a)}}
  end

  def fill_to_size(a, window)
      when is_binary(a) and byte_size(a) > window do
    <<b::binary-size(^window), rest::binary>> = a
    {b, rest}
  end

  def fill_to_size([], window), do: {"", {:rem, window}}

  def fill_to_size([a | rest], window) do
    case fill_to_size(a, window) do
      {b, {:rem, rem}} ->
        {c, c_rest} = fill_to_size(rest, rem)
        {[b, c], c_rest}

      {b, b_rest} ->
        {b, [b_rest, rest]}
    end
  end
end
