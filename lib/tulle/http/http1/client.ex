defmodule Tulle.Http1.Client do
  @moduledoc """
  HTTP1 Client. Used with `Tulle.Http`.

  Tries to reconnect when the connection is lost,
  exits if it can't reconnect with `{:cant_connect, reason}`
  """

  use GenServer

  require Logger
  alias Mint.HTTP1

  @type t :: GenServer.name()

  def start_link(opts) do
    connect_args =
      Enum.filter(opts, fn {k, _} -> k in [:scheme, :address, :port, :connect_opts] end)

    GenServer.start_link(__MODULE__, connect_args, opts)
  end

  defp default_connect_opts(:https) do
    [transport_opts: [cacerts: :public_key.cacerts_get()]]
  end

  defp default_connect_opts(:http), do: []

  @impl true
  def init(connect_args) do
    case connect(connect_args) do
      {:ok, conn} ->
        {:ok,
         %{
           conn: conn,
           req_ref: nil,
           req_caller: nil,
           status: :idle,
           connect_args: connect_args
         }}

      {:error, error} ->
        {:stop, {:cant_connect, error}}
    end
  end

  defp connect(connect_args) do
    scheme = connect_args[:scheme] || :https

    connect_opts =
      DeepMerge.deep_merge(default_connect_opts(scheme), connect_args[:connect_opts] || [])

    HTTP1.connect(
      scheme,
      connect_args[:address],
      connect_args[:port] || 443,
      connect_opts
    )
  end

  @impl true
  def handle_call(:protocol, _from, state), do: {:reply, :http1, state}

  def handle_call({:request, caller, {m, p, h}, b}, _, %{status: :idle} = state)
      when b != :request do
    with {:ok, conn, ref} <- HTTP1.request(state.conn, m, p, h, b) do
      state = %{state | conn: conn, req_ref: ref, req_caller: caller, status: :sent}
      {:reply, {:ok, ref}, state}
    end
  end

  def handle_call({:request_stream, caller, {m, p, h}}, _, %{status: :idle} = state) do
    with {:ok, conn, ref} <-
           HTTP1.request(state.conn, m, p, h, :stream) |> maybe_reply_error(state) do
      state = %{state | conn: conn, req_ref: ref, req_caller: caller, status: :sending}
      {:reply, {:ok, ref}, state}
    end
  end

  def handle_call({:chunk, ref, :eof}, _, %{status: :sending, req_ref: ref} = state) do
    with {:ok, conn} <-
           HTTP1.stream_request_body(state.conn, state.req_ref, :eof)
           |> maybe_reply_error(state) do
      state = %{state | conn: conn, status: :sent}
      {:reply, :ok, state}
    end
  end

  def handle_call({:chunk, ref, data}, _, %{status: :sending, req_ref: ref} = state) do
    with {:ok, conn} <- HTTP1.stream_request_body(state.conn, state.req_ref, data) do
      state = %{state | conn: conn}
      {:reply, :ok, state}
    end
  end

  defp maybe_reply_error({:error, conn, error}, state) do
    state = %{state | conn: conn}
    {:reply, {:error, error}, state} |> maybe_reconnect_reply()
  end

  defp maybe_reply_error(mint_result, _state) do
    mint_result
  end

  @impl true
  def handle_info(msg, %{status: :sent} = state) do
    case HTTP1.stream(state.conn, msg) do
      #
      {:ok, conn, resps} ->
        Enum.each(
          resps,
          fn resp ->
            send(state.req_caller, resp)
          end
        )

        done = Enum.find(resps, &match?({:done, _}, &1))

        state =
          case done do
            nil -> %{state | conn: conn}
            _ -> %{state | conn: conn, status: :idle}
          end

        {:noreply, state}

      #
      {:error, conn, err, resps} ->
        Enum.each(resps, &send(state.req_caller, &1))
        send(state.req_caller, {:error, err})
        state = %{state | conn: conn}
        {:noreply, state}
    end
    |> maybe_reconnect_noreply()
  end

  def handle_info(msg, state) do
    case HTTP1.stream(state.conn, msg) do
      {:ok, conn, []} ->
        state = %{state | conn: conn}
        {:noreply, state} |> maybe_reconnect_noreply()

      {:error, conn, error, []} ->
        Logger.debug(http_error: error, status: state.status)
        state = %{state | conn: conn}
        {:noreply, state} |> maybe_reconnect_noreply()
    end
  end

  @impl true
  def handle_continue(:reconnect, state) do
    conn = state.conn
    {:ok, _conn} = HTTP1.close(conn)

    case connect(state.connect_args) do
      {:ok, conn} ->
        state = %{state | conn: conn, status: :idle}
        {:noreply, state}

      {:error, error} ->
        {:stop, {:cant_connect, error}, state}
    end
  end

  defp maybe_reconnect_noreply({:noreply, state}) do
    if HTTP1.open?(state.conn) do
      {:noreply, state}
    else
      state = %{state | status: :closed}
      {:noreply, state, {:continue, :reconnect}}
    end
  end

  defp maybe_reconnect_reply({:reply, msg, state}) do
    if HTTP1.open?(state.conn) do
      {:reply, msg, state}
    else
      state = %{state | status: :closed}
      {:reply, msg, state, {:continue, :reconnect}}
    end
  end
end
