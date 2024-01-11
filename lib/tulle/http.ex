defmodule Tulle.HTTP do
  @moduledoc """
  Make HTTP requests with a `Tulle.HTTP1.Client` or `Tulle.HTTP2.Client`.
  """

  alias __MODULE__.Request

  @typedoc """
  A `Collectable` that writes to an HTTP request stream.

  Created with `request_collectable!/2`.
  When done sending, `close_request!/1` must be called to signal the EOF.
  """
  @opaque request :: __MODULE__.Request.t()

  @typedoc """
  A `Tulle.HTTP1.Client` or `Tulle.HTTP2.Client` or process.
  """
  @type client :: Tulle.HTTP1.Client.http1_client() | Tulle.HTTP2.Client.http2_client()

  @typedoc """
  Method-path-header triple.

  req_params(atom) would indicate method can be either a string or atom.
  """
  @type req_params(method_alt) ::
          {method :: String.t() | method_alt, path :: String.t(), Mint.Types.headers()}

  @spec request!(client(), req_params(atom()), iodata() | nil, timeout()) ::
          {pos_integer(), Mint.Types.headers(), iodata_stream :: Enum.t()}
  @doc """
  Sends a request. Returns a triple of the status, the headers, and the response body stream.
  """
  def request!(
        client,
        {method, path, headers} = _meth_path_headers,
        body,
        timeout \\ 10_000
      ) do
    method = method |> to_string() |> String.upcase()

    case GenServer.call(
           client,
           {:request, self(), {method, path, headers}, body},
           timeout
         ) do
      {:ok, ref} ->
        receive_stream(ref)

      {:error, error} ->
        raise error
    end
  end

  @spec request_collectable!(client, req_params(atom)) :: request()
  @doc """
  Start a streaming request.

  The returned `t:request/0` object can be `Enum.into/2`'ed.
  Call `close_request!/1` to signal the EOF.
  """
  def request_collectable!(client, {method, path, headers}) do
    method = method |> to_string() |> String.upcase()

    {:ok, ref} =
      GenServer.call(client, {:request_stream, self(), {method, path, headers}})

    %Request{client: client, ref: ref}
  end

  @spec close_request!(request()) ::
          {pos_integer(), Mint.Types.headers(), iodata_stream :: Enum.t()}
  @doc """
  Sends EOF for the collectable returned by `request_collectable!/2`.

  Returns a triple of the status, the headers, and the response body stream.
  """
  def close_request!(%Request{client: client, ref: ref}) do
    :ok = GenServer.call(client, {:chunk, ref, :eof})

    receive_stream(ref)
  end

  @spec set_info(request(), any) :: request()
  @doc """
  Put arbitrary custom data that can be accessed with `get_info/1`
  """
  defdelegate set_info(request, info), to: __MODULE__.Request

  @spec get_info(request()) :: any()
  @doc """
  Get the custom data that was put with `set_info/2`
  """
  defdelegate get_info(request), to: __MODULE__.Request

  defp receive_stream(ref) do
    status =
      receive do
        {:status, ^ref, status} -> status
        {:error, ^ref, reason} -> raise reason
      end

    headers =
      receive do
        {:headers, ^ref, headers} -> headers
        {:error, ^ref, reason} -> raise reason
      end

    body_stream =
      Stream.repeatedly(fn ->
        receive do
          {:data, ^ref, data} -> data
          {:done, ^ref} -> :done
          {:error, ^ref, reason} -> raise reason
        end
      end)
      |> Stream.take_while(&(&1 != :done))

    {status, headers, body_stream}
  end

  defimpl Collectable, for: Request do
    # Un-opaque
    @type t :: %Request{client: client, ref: Mint.Types.request_ref()}
    @type client :: GenServer.name()

    @spec into(t()) :: {t(), (t(), :done | :halt | {:cont, iodata()} -> t())}
    def into(%Request{client: client, ref: ref} = coll)
        when client != self() and client != nil and ref != nil do
      collector = fn
        %Request{client: client, ref: ref} = coll, {:cont, data} ->
          :ok = GenServer.call(client, {:chunk, ref, data}, :infinity)
          coll

        %Request{client: client, ref: ref} = coll, :halt ->
          if :http2 == GenServer.call(client, :protocol, 100) do
            :ok = GenServer.call(client, {:chunk, ref, :cancel}, :infinity)
          end

          coll

        %Request{} = coll, :done ->
          coll
      end

      {coll, collector}
    end
  end
end
