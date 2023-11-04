defmodule Tulle.Websocket do
  @moduledoc """
  Websocket client, implemented as a Genserver.

  Expects a message handler GenServer that can be `cast`ed with:

  * `{:text, websocket_pid, msg :: binary}`
  * `{:binary, websocket_pid, msg :: binary}`
  * `{:closed, websocket_pid, close_code :: non_neg_integer() | nil}`
  * `{:warning, websocket_pid, reason :: any}`

  """

  require Mint.HTTP
  alias Mint.HTTP
  alias Mint.WebSocket, as: Ws
  import Map
  require Logger

  use GenServer

  @ping_interval 10_000

  @spec start_link(GenServer.server(), GenServer.options()) :: GenServer.on_start()
  def start_link(msg_handler, opts) do
    GenServer.start_link(__MODULE__, msg_handler, opts)
  end

  @spec connect(
          GenServer.server(),
          String.t() | URI.t(),
          Mint.Types.headers(),
          [module()]
        ) ::
          :ok | {:error, term}
  def connect(ws, url, headers, extensions \\ [Ws.PerMessageDeflate]) do
    GenServer.call(ws, {:connect, url, headers, extensions})
  end

  @spec send(GenServer.server(), :binary | :text, binary() | String.t()) ::
          :ok | {:error, term}
  def send(ws, type, msg) do
    GenServer.call(ws, {:send, type, msg})
  end

  @spec close(GenServer.server(), pos_integer() | nil) ::
          :ok | {:ok, :timeout | term} | {:error, term}
  def close(ws, code) do
    GenServer.call(ws, {:close, code})
  end

  @impl GenServer
  def init(msg_handler) do
    Process.flag(:trap_exit, true)
    data = %{msg_handler: msg_handler}
    {:ok, {:closed, data}}
  end

  ## Connect call ##
  @impl GenServer
  def handle_call({:connect, url, headers, extensions}, from, {:closed, data}) do
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
      timer = Process.send_after(self(), {:handshake_timeout, from}, 10_000)

      {:noreply, {[:waiting_hs_resp, from], put(data, :hs_timer, timer)}}
      ##
    else
      {:error, reason} ->
        Logger.error("Could not connect to #{i(domain)}, #{i(reason)}")
        {:reply, {:error, reason}, {:closed, data}}

      {:error, conn, reason} ->
        Logger.error("Could not send upgrade request to #{i(domain)}, #{i(reason)}")
        {:reply, {:error, reason}, {:closed, put(data, :conn, conn)}}
    end
  end

  ## Send call ##
  @impl GenServer
  def handle_call({:send, type, msg}, _from, {:open, data}) do
    Logger.debug("Sending msg")
    {:ok, websocket, encoded} = Ws.encode(data.websocket, {type, msg})

    case Ws.stream_request_body(data.conn, data.ref, encoded) do
      {:ok, conn} ->
        {:reply, :ok, {:open, %{data | conn: conn, websocket: websocket}}}

      {:error, conn, err} ->
        {:reply, {:error, err}, {:open, %{data | conn: conn, websocket: websocket}}}
    end
  end

  ## Close call ##
  @impl GenServer
  def handle_call({:close, code}, from, {:open, data}) do
    Logger.debug("Initiating closing with #{code}.")
    {:ok, websocket, encoded} = Ws.encode(data.websocket, {:close, code, ""})

    conn =
      case Ws.stream_request_body(data.conn, data.ref, encoded) do
        {:ok, conn} ->
          conn

        {:error, conn, err} ->
          Logger.warning("Can't send close: #{i(err)}")
          conn
      end

    close_timer = Process.send_after(self(), {:close_timeout, data.ref}, 2_000)
    data = merge(data, %{close_timer: close_timer, conn: conn, websocket: websocket})
    {:noreply, {{:closing, from}, data}}
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
    GenServer.reply(from, {:error, :timeout})
    {:noreply, {:closed, data}}
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
        GenServer.reply(from, {:error, error})
        {:noreply, {:closed, %{data | conn: conn}}}
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
          [:waiting_hs_resp, from, _status, _headers, :ws_created],
          %{ref: ref} = data
        }
      ) do
    Logger.debug("Handshake OK")
    Logger.debug("Creating ping timer.")
    Process.cancel_timer(data.hs_timer)
    GenServer.reply(from, :ok)
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

    {:noreply, {:open, data}}
  end

  ## Open

  ### Send ping
  @impl GenServer
  def handle_info({:ping_time, ref}, {:open, %{ref: ref} = data}) do
    unless data.pong_received do
      Logger.warning("Websocket ping timed out.")

      GenServer.cast(
        data.msg_handler,
        {:warning, self(), {:ping_timeout, @ping_interval}}
      )
    end

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

    if HTTP.open?(conn) do
      Process.send_after(self(), {:ping_time, ref}, @ping_interval)
      {:noreply, {:open, data}}
    else
      Logger.warning("Connection closed unexpectedly.")
      GenServer.cast(data.msg_handler, {:closed, self(), nil})
      {:noreply, {:closed, %{data | conn: conn}}}
    end
  end

  ### Receive msgs, send self each frame
  @impl GenServer
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

    {conn, websocket} =
      with {:ok, websocket, encoded} <- Ws.encode(data.websocket, {:pong, msg}),
           {:ok, conn} <- Ws.stream_request_body(data.conn, data.ref, encoded) do
        {conn, websocket}
      else
        {:error, conn, err} ->
          Logger.warning("Can't send pong: #{i(err)}")
          {conn, data.websocket}
      end

    {:noreply, {:open, %{data | conn: conn, websocket: websocket}}}
  end

  ### Receive data
  @impl GenServer
  def handle_info({:frame, ref, {:text, msg}}, {:open, data}) when ref == data.ref do
    Logger.debug("Received text data, #{i(binary_slice(msg, 1..10))}")
    GenServer.cast(data.msg_handler, {:text, self(), msg})
    {:noreply, {:open, data}}
  end

  @impl GenServer
  def handle_info({:frame, ref, {:binary, msg}}, {:open, data}) when ref == data.ref do
    Logger.debug("Received binary data, #{i(binary_slice(msg, 1..10))}")
    GenServer.cast(data.msg_handler, {:binary, self(), msg})
    {:noreply, {:open, data}}
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

    GenServer.cast(data.msg_handler, {:closed, self(), code})

    data = %{data | conn: conn, websocket: websocket}

    {:noreply, {:closed, data}}
  end

  ### Receive errored frame 
  def handle_info({:frame, ref, {:error, reason}}, {:open, data})
      when ref == data.ref do
    Logger.error("Could not decode frame: #{i(reason)}")
    {:noreply, {:open, data}}
  end

  ## Closing

  ### Closing timeout
  def handle_info({:close_timeout, ref}, {{:closing, from}, data})
      when ref == data.ref do
    Logger.warning("Timed out waiting for server close response.")
    Logger.info("Connection closed: #{i(nil)}")
    {:ok, conn} = HTTP.close(data.conn)
    GenServer.reply(from, {:ok, :timeout})

    GenServer.cast(data.msg_handler, {:closed, self(), nil})

    {:noreply, {:closed, %{data | conn: conn}}}
  end

  ### Receive msgs, send self each frame
  @impl GenServer
  def handle_info(msg, {{:closing, from}, %{conn: conn} = data})
      when HTTP.is_connection_message(conn, msg) do
    # if stream/2 returns error, ignore
    {conn, websocket} = parse_msg(msg, conn, data.websocket, data.ref)

    {:noreply, {{:closing, from}, %{data | conn: conn, websocket: websocket}}}
  end

  ### Receive close
  @impl GenServer
  def handle_info({:frame, ref, {:close, code, _reason}}, {{:closing, from}, data})
      when ref == data.ref do
    Logger.debug("Received back close #{code}")

    Process.cancel_timer(data.close_timer)
    GenServer.cast(data.msg_handler, {:closed, self(), code})

    GenServer.reply(from, {:ok, code})

    {:noreply, {:closed, data}}
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
  def handle_info(msg, {state, data}) do
    Logger.warning("Received unhandled message #{i(msg)} when state is #{i(state)}")
    {:noreply, {state, data}}
  end

  ### Terminate handler
  @impl GenServer
  def terminate(reason, {state, data}) do
    if state == :open and HTTP.open?(data.conn) do
      code =
        if reason == :normal or reason == :shutdown or match?({:shutdown, _}, reason),
          do: 1000,
          else: 1011

      {:ok, _websocket, encoded} = Ws.encode(data.websocket, {:close, code, ""})

      case Ws.stream_request_body(data.conn, data.ref, encoded) do
        {:ok, _conn} -> Logger.debug("Sent close with #{i(code)}.")
        {:error, _conn, err} -> Logger.warning("Can't send close: #{i(err)}")
      end
    end
  end

  ### Helper funs

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
