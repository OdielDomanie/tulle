defmodule Tulle.Websocket do
  @moduledoc """
  Websocket client, implemented as a Genserver.
  """

  require Mint.HTTP
  alias Mint.HTTP
  alias Mint.WebSocket, as: Ws
  import Map
  require Logger

  use GenServer

  @type handle_result ::
          {:ok, state :: any}
          | {:push, message() | [message()], state :: any}
          | {:close, code | {code, binary}, state :: any}
  @type message :: {:text | :binary, binary}
  @type code :: 1000..4999

  @callback handle_connect(state :: any) :: handle_result()
  @callback handle_in(message, state :: any) :: handle_result()
  @callback handle_remote_close(code | nil, reason :: binary | nil, state :: any) :: any

  defmacro __using__(opts) do
    quote do
      @behaviour Tulle.Websocket

      def child_spec(init_arg) do
        default = %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [init_arg]}
        }

        Supervisor.child_spec(default, unquote(Macro.escape(opts)))
      end
    end
  end

  @ping_interval 10_000

  @typedoc """
  Must have `:url`, optionally can have `:headers` and `:extensions`.
  (defaults to `PerMessageDeflate`).
  """
  @type conn_opts :: Access.t()

  @spec start_link(WebSock.impl(), any, conn_opts, GenServer.options()) ::
          GenServer.on_start()
  def start_link(module, init_args, conn_opts, opts \\ []) do
    url = conn_opts[:url]
    headers = conn_opts[:headers] || []
    extensions = conn_opts[:extensions] || [Ws.PerMessageDeflate]
    GenServer.start_link(__MODULE__, {module, init_args, {url, headers, extensions}}, opts)
  end

  @spec send(GenServer.server(), :binary | :text, binary() | String.t()) ::
          :ok | {:error, term}
  def send(ws, type, msg) do
    GenServer.call(ws, {:send, type, msg})
  end

  @spec close(GenServer.server(), code) ::
          {:ok, code | :timeout} | {:unclean, error :: term}
        when code: 1000..4999
  def close(ws, code) do
    GenServer.call(ws, {:close, code})
  end

  @impl GenServer
  def init({msg_handler, cust_data, {url, headers, extensions}}) do
    Process.flag(:trap_exit, true)
    data = %{msg_handler: msg_handler, cust_data: cust_data}
    {:ok, {:closed, data}, {:continue, {:connect, url, headers, extensions}}}
  end

  ## Connect ##
  @impl GenServer
  def handle_continue({:connect, url, headers, extensions}, {:closed, data}) do
    url = URI.new!(url)
    domain = url.host

    _ = {:http, :https, :ws, :wss}
    scheme = String.to_existing_atom(url.scheme)
    # There are different conventions for when to use :ws and :http (?),
    # so make sure.
    http_scheme = to_http_scheme(scheme)
    ws_scheme = to_ws_scheme(scheme)

    path = %URI{path: url.path, query: url.query} |> URI.to_string()

    ok_conn =
      if data[:conn] && HTTP.open?(data[:conn]) && data[:domain] == domain do
        Logger.debug("Reusing connection")
        {:ok, data[:conn]}
      else
        Logger.debug("Opening a new connection")
        data[:conn] && HTTP.close(data[:conn])

        HTTP.connect(http_scheme, domain, url.port,
          protocols: [:http1],
          transport_opts:
            if(http_scheme == :https,
              do: [cacerts: :public_key.cacerts_get()],
              else: []
            )
        )
      end

    with {:ok, conn} <- ok_conn,
         _ = Logger.debug("Connected"),
         {:ok, conn, ref} <-
           Ws.upgrade(
             ws_scheme,
             conn,
             path,
             headers,
             extensions: extensions
           ) do
      Logger.debug("Sent Websocket upgrade request")
      data = merge(data, %{conn: conn, ref: ref, domain: domain})

      # spagetthi!
      from = nil
      timer = Process.send_after(self(), {:handshake_timeout, from}, 10_000)

      {:noreply, {[:waiting_hs_resp, from], put(data, :hs_timer, timer)}}
      ##
    else
      {:error, reason} ->
        Logger.error("Could not connect to #{i(domain)}, #{i(reason)}")
        {:stop, reason, {:closed, data}}

      {:error, conn, reason} ->
        Logger.error("Could not send upgrade request to #{i(domain)}, #{i(reason)}")
        {:stop, reason, {:closed, put(data, :conn, conn)}}
    end
  end

  ## Send call ##
  @impl GenServer
  def handle_call({:send, type, msg}, _from, {:open, data}) do
    case do_send(data, type, msg) do
      {:ok, data} ->
        {:reply, :ok, {:open, data}}

      {:error, data, err} ->
        {:reply, {:error, err}, {:open, data}}
    end
  end

  ## Close call ##
  @impl GenServer
  def handle_call({:close, code}, from, {:open, data}) do
    case do_send_close(code, nil, data) do
      {:ok, data} ->
        {:noreply, {{:closing, from}, data}}

      {:error, data, err} ->
        GenServer.reply(from, {:unclean, err})
        {:stop, err, data}
    end
  end

  ## Catch-all call ##
  @impl GenServer
  def handle_call(_, _from, {state, data}) do
    {:reply, {:error, state}, {state, data}}
  end

  ## Receive responses, seperate them and send back to self
  @dialyzer {:no_opaque, handle_info: 2}
  @impl GenServer
  def handle_info(msg, {[:waiting_hs_resp, _from] = state, %{conn: conn} = data})
      when HTTP.is_connection_message(conn, msg) do
    {conn, responses} =
      case Ws.stream(conn, msg) do
        {:ok, conn, responses} ->
          Logger.debug("Received a handshake response.")
          {conn, responses}

        {:error, conn, error, responses} ->
          Logger.warning(i({state, error}))
          {conn, responses}
      end

    data = put(data, :conn, conn)

    {state, data} =
      for resp <- responses, reduce: {state, data} do
        {state, data} ->
          {:noreply, {state, data}} = handle_info({:resp, resp}, {state, data})
          {state, data}
      end

    {:noreply, {state, data}}
  end

  ## Handshake timeout
  def handle_info(
        {:handshake_timeout, from},
        {[:waiting_hs_resp, from | _], data}
      ) do
    Logger.error("Websocket handshake timed-out")
    # GenServer.reply(from, {:error, :timeout})
    {:stop, :handshake_timeout, {:closed, data}}
  end

  ## Process the responses

  def handle_info(
        {:resp, {:status, ref, status}},
        {[:waiting_hs_resp, from], %{ref: ref} = data}
      ) do
    Logger.debug("Received handshake response status.")
    {:noreply, {[:waiting_hs_resp, from, status], data}}
  end

  def handle_info(
        {:resp, {:headers, ref, headers}},
        {[:waiting_hs_resp, from, status], %{ref: ref} = data}
      ) do
    case Ws.new(data.conn, ref, status, headers) do
      {:ok, conn, websock} ->
        Logger.debug("Received handshake response headers.")
        data = merge(data, %{conn: conn, websocket: websock})
        {:noreply, {[:waiting_hs_resp, from, status, headers, :ws_created], data}}

      {:error, conn, error} ->
        Logger.error("Error when creating websocket: #{i(error)}")
        Process.cancel_timer(data.hs_timer)
        # GenServer.reply(from, {:error, error})
        # {:noreply, {:closed, %{data | conn: conn}}}
        {:stop, error, {:closed, %{data | conn: conn}}}
    end
  end

  # If a data frame arrives before `:done`
  def handle_info(
        {:resp, {:data, ref, msg_data}},
        {
          [:waiting_hs_resp, _from, _status, _headers, :ws_created] = state,
          %{ref: ref} = data
        }
      ) do
    data = put(data, :upgrade_resp_data, {msg_data, ref})

    Logger.debug("Received data within handshake")

    {:noreply, {state, data}}
  end

  def handle_info(
        {:resp, {:done, ref}},
        {
          [:waiting_hs_resp, _from, _status, _headers, :ws_created],
          %{ref: ref} = data
        }
      ) do
    Logger.debug("Handshake OK")
    Logger.debug("Creating ping timer.")
    Process.cancel_timer(data.hs_timer)
    ping_timer = Process.send_after(self(), {:ping_time, ref}, @ping_interval)
    data = put(data, :ping_timer, ping_timer)
    data = put(data, :pong_received, true)

    data =
      case data[:upgrade_resp_data] do
        {msg_data, ref} ->
          websocket = msg_data_to_frames_send(data.websocket, msg_data, ref)
          data = delete(data, :upgrade_resp_data)
          put(data, :websocket, websocket)

        nil ->
          data
      end

    apply(data.msg_handler, :handle_connect, [data.cust_data])
    |> do_handle_result({:open, data})
  end

  ## Open

  ### Send ping
  def handle_info({:ping_time, ref}, {:open, %{ref: ref, pong_received: true} = data}) do
    {:ok, websocket, encoded} = Ws.encode(data.websocket, :ping)

    conn =
      case Ws.stream_request_body(data.conn, data.ref, encoded) do
        {:ok, conn} ->
          Logger.debug("Sent ping.")
          conn

        {:error, conn, err} ->
          Logger.warning("Can't send ping: #{i(err)}")
          conn
      end

    data = merge(data, %{pong_received: false, conn: conn, websocket: websocket})

    Process.send_after(self(), {:ping_time, ref}, @ping_interval)
    {:noreply, {:open, data}}
  end

  def handle_info({:ping_time, ref}, {:open, %{ref: ref, pong_received: false} = data}) do
    Logger.error("Websocket pong timed out.")

    {:stop, {:protocol_error, :pong_timeout}, data}
  end

  ### Receive msgs, send self each frame
  def handle_info(msg, {:open, %{conn: conn} = data})
      when HTTP.is_connection_message(conn, msg) do
    # if stream/2 returns error, ignore

    {conn, websocket} = parse_msg(msg, conn, data.websocket, data.ref)

    {:noreply, {:open, %{data | conn: conn, websocket: websocket}}}
  end

  @impl GenServer
  def handle_info({:frames, ref, msg_data}, {:open, data}) when ref == data.ref do
    websocket = msg_data_to_frames_send(data.websocket, msg_data, data.ref)
    {:noreply, {:open, %{data | websocket: websocket}}}
  end

  ### Receive pong
  @impl GenServer
  def handle_info({:frame, ref, {:pong, msg}}, {:open, data}) when ref == data.ref do
    Logger.debug("Received pong, #{i(msg)}")
    {:noreply, {:open, %{data | pong_received: true}}}
  end

  ### Receive ping
  @impl GenServer
  def handle_info({:frame, ref, {:ping, msg}}, {:open, data}) when ref == data.ref do
    Logger.debug("Received ping, ponging: #{i(msg)}")

    case Ws.encode(data.websocket, {:pong, msg}) do
      {:ok, websocket, encoded} ->
        case Ws.stream_request_body(data.conn, data.ref, encoded) do
          {:ok, conn} ->
            {:noreply, {:open, %{data | conn: conn, websocket: websocket}}}

          {:error, conn, err} ->
            Logger.error("Can't send pong: #{i(err)}")
            {:noreply, {:open, %{data | conn: conn, websocket: websocket}}}
        end

      {:error, websocket, error} ->
        Logger.warning("Can't encode pong: #{i(error)}")

        case error do
          %Mint.WebSocketError{reason: :payload_too_large} ->
            reason = {:protocol_error, error}
            {:stop, reason, {:open, %{data | websocket: websocket}}}

          _ ->
            {:noreply, {:open, %{data | websocket: websocket}}}
        end
    end
  end

  ### Receive data
  @impl GenServer
  def handle_info({:frame, ref, {:text, msg}}, {:open, data}) when ref == data.ref do
    Logger.debug("Received text data, #{i(binary_slice(msg, 1..10))}")

    apply(data.msg_handler, :handle_in, [{:text, msg}, data.cust_data])
    |> do_handle_result({:open, data})
  end

  @impl GenServer
  def handle_info({:frame, ref, {:binary, msg}}, {:open, data}) when ref == data.ref do
    Logger.debug("Received binary data, #{i(binary_slice(msg, 1..10))}")

    apply(data.msg_handler, :handle_in, [{:binary, msg}, data.cust_data])
    |> do_handle_result({:open, data})
  end

  ### Receive close
  @impl GenServer
  def handle_info({:frame, ref, {:close, code, reason}}, {:open, data})
      when ref == data.ref do
    Logger.debug("Received close #{code}, sending close back. reason: #{i(reason)}")

    {:ok, websocket, encoded} = Ws.encode(data.websocket, {:close, code, ""})

    conn =
      case Ws.stream_request_body(data.conn, data.ref, encoded) do
        {:ok, conn} ->
          conn

        {:error, conn, err} ->
          Logger.warning("Can't reply close: #{i(err)}")
          conn
      end

    data = %{data | conn: conn, websocket: websocket}

    _ = apply(data.msg_handler, :handle_remote_close, [code, reason, data.cust_data])

    {:stop, :normal, {:closed, data}}
  end

  ### Receive errored frame
  def handle_info({:frame, ref, {:error, reason}}, {:open, data} = state)
      when ref == data.ref do
    case reason do
      {:invalid_utf8, _} ->
        Logger.error("Could not decode frame: #{i(reason)}")
        {:stop, {:invalid_data, reason}, state}

      _ ->
        Logger.error("Could not decode frame: #{i(reason)}")
        {:stop, {:protocol_error, reason}, state}
    end
  end

  ## Closing

  ### Closing timeout
  def handle_info({:close_timeout, ref}, {{:closing, from}, data})
      when ref == data.ref do
    Logger.warning("Timed out waiting for server close response.")
    Logger.info("Connection closed: #{i(nil)}")
    {:ok, conn} = HTTP.close(data.conn)

    if from, do: GenServer.reply(from, {:ok, :timeout})

    {:stop, :normal, {:closed, %{data | conn: conn}}}
  end

  ### Receive msgs, send self each frame
  @impl GenServer
  def handle_info(msg, {{:closing, from}, %{conn: conn} = data})
      when HTTP.is_connection_message(conn, msg) do
    # if stream/2 returns error, ignore
    {conn, websocket} = parse_msg(msg, conn, data.websocket, data.ref)

    {:noreply, {{:closing, from}, %{data | conn: conn, websocket: websocket}}}
  end

  ### Receive close as reply
  @impl GenServer
  def handle_info({:frame, ref, {:close, code, _reason}}, {{:closing, from}, data})
      when ref == data.ref do
    Logger.debug("Received back close #{code}")

    Process.cancel_timer(data.close_timer)

    if from, do: GenServer.reply(from, {:ok, code})

    {:stop, :normal, {:closed, data}}
  end

  ### Catch-all

  @impl GenServer
  def handle_info({:ping_time, _ref}, state) do
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(msg, {state, %{conn: conn} = data})
      when HTTP.is_connection_message(conn, msg) do
    conn =
      Ws.stream(conn, msg)
      |> case do
        {:ok, conn, []} ->
          Logger.debug("Received msg #{i(msg)} when state is #{i(state)}")
          conn

        {:ok, conn, resps} ->
          Logger.warning("Received unhandled resps #{i(resps)} when state is #{i(state)}")

          conn

        {:error, conn, err, resps} ->
          Logger.debug(
            "Received unhandled resps #{i(resps)} when state is #{i(state)}, and errored with #{i(err)}"
          )

          conn
      end

    {:noreply, {state, %{data | conn: conn}}}
  end

  @impl GenServer
  def handle_info(msg, {status, data}) do
    Logger.warning("Received unhandled message #{i(msg)} when state is #{i(status)}")
    {:noreply, {status, data}}
  end

  ### Terminate handler
  @impl GenServer
  def terminate(reason, {:open, data}) do
    code =
      case reason do
        :normal -> 1000
        :shutdown -> 1000
        {:shutdown, {:code, code}} when code in 1000..4999 -> code
        {:shutdown, _} -> 1000
        {:protocol_error, _err} -> 1002
        {:invalid_data, _err} -> 1007
        {:code, code} when code in 1000..4999 -> code
        _else -> 1011
      end

    {:ok, _websocket, encoded} = Ws.encode(data.websocket, {:close, code, ""})

    Logger.info("Closing the websocket with #{code}")

    case Ws.stream_request_body(data.conn, data.ref, encoded) do
      {:ok, _conn} -> Logger.debug("Sent close with #{i(code)}.")
      {:error, _conn, err} -> Logger.warning("Can't send close: #{i(err)}")
    end
  end

  def terminate(_reason, {_status, _data}) do
  end

  ### Helper funs

  defp do_handle_result({:ok, cust_data}, {status, data}) do
    data = %{data | cust_data: cust_data}
    {:noreply, {status, data}}
  end

  defp do_handle_result({:push, msgs, cust_data}, {status, data}) when is_list(msgs) do
    data = %{data | cust_data: cust_data}

    case send_multiple(data, msgs) do
      {:ok, data} ->
        {:noreply, {status, data}}

      {:error, data, err} ->
        {:stop, err, {status, data}}
    end
  end

  defp do_handle_result({:push, {type, content}, cust_data}, {status, data}) do
    data = %{data | cust_data: cust_data}

    case do_send(data, type, content) do
      {:ok, data} ->
        {:noreply, {status, data}}

      {:error, data, err} ->
        {:stop, err, {status, data}}
    end
  end

  # {:close, code | {code, binary}, state :: any}

  defp do_handle_result({:close, {code, reason}, cust_data}, {:open, data}) do
    data = %{data | cust_data: cust_data}

    case do_send_close(code, reason, data) do
      {:ok, data} -> {:noreply, {{:closing, nil}, data}}
      {:error, data, error} -> {:stop, error, {{:closing, nil}, data}}
    end
  end

  defp do_handle_result({:close, code, cust_data}, {:open, data}) do
    data = %{data | cust_data: cust_data}

    case do_send_close(code, nil, data) do
      {:ok, data} -> {:noreply, {{:closing, nil}, data}}
      {:error, data, error} -> {:stop, error, {{:closing, nil}, data}}
    end
  end

  defp do_send_close(code, _reason, data) do
    Logger.debug("Initiating closing with #{code}.")

    {:ok, websocket, encoded} = Ws.encode(data.websocket, {:close, code, ""})

    case Ws.stream_request_body(data.conn, data.ref, encoded) do
      {:ok, conn} ->
        close_timer = Process.send_after(self(), {:close_timeout, data.ref}, 2_000)
        data = merge(data, %{close_timer: close_timer, conn: conn, websocket: websocket})
        {:ok, data}

      {:error, conn, err} ->
        Logger.warning("Can't send close: #{i(err)}")
        data = merge(data, %{conn: conn, websocket: websocket})

        {:error, data, err}
    end
  end

  defp do_send(data, type, msg) do
    Logger.debug("Sending msg")

    {:ok, websocket, encoded} = Ws.encode(data.websocket, {type, msg})

    case Ws.stream_request_body(data.conn, data.ref, encoded) do
      {:ok, conn} ->
        {:ok, %{data | conn: conn, websocket: websocket}}

      {:error, conn, err} ->
        {:error, %{data | conn: conn, websocket: websocket}, err}
    end
  end

  defp send_multiple(data, []), do: {:ok, data}

  defp send_multiple(data, [{type, content} | rest]) do
    case do_send(data, type, content) do
      {:ok, data} -> send_multiple(data, rest)
      {:error, _data, _err} = err_tuple -> err_tuple
    end
  end

  @dialyzer {:no_opaque, parse_msg: 4}
  @dialyzer {:no_return, parse_msg: 4}
  @spec parse_msg(any, HTTP.t(), Ws.t(), Mint.Types.request_ref()) :: {HTTP.t(), Ws.t()}
  defp parse_msg(msg, conn, websocket, ref) do
    {conn, resps} =
      case Ws.stream(conn, msg) do
        {:ok, conn, resps} ->
          {conn, resps}

        # if stream/2 returns error, ignore
        {:error, conn, error, resps} ->
          Logger.error("Received bad response: #{i(error)}")
          {conn, resps}
      end

    websocket =
      for {:data, ^ref, msg_data} <- resps, reduce: websocket do
        websocket ->
          msg_data_to_frames_send(websocket, msg_data, ref)
      end

    {conn, websocket}
  end

  defp msg_data_to_frames_send(websocket, msg_data, ref) do
    Ws.decode(websocket, msg_data)
    |> case do
      {:ok, websocket, frames} ->
        for frame <- frames do
          send(self(), {:frame, ref, frame})
        end

        websocket

      {:error, websocket, reason} ->
        Logger.error("Could not decode frame: #{i(reason)}")
        websocket
    end
  end

  defp to_http_scheme(:ws), do: :http
  defp to_http_scheme(:wss), do: :https
  defp to_http_scheme(scheme), do: scheme

  defp to_ws_scheme(:http), do: :ws
  defp to_ws_scheme(:https), do: :wss
  defp to_ws_scheme(scheme), do: scheme

  defp i(arg) do
    inspect(arg, binaries: :as_strings)
  end
end
