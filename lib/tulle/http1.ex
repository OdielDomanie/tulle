defmodule Tulle.Http1 do
  alias __MODULE__.Client

  @spec request!(Client.t(), atom, String.t(), Mint.Types.headers(), iodata() | nil) ::
          {200..599, Mint.Types.headers(), Enum.t()}
  def request!(client, method, path, headers, body) do
    ref = Client.request!(client, method, path, headers, body)

    status =
      receive do
        {:status, ^ref, status} when status in 200..599 -> status
      end

    headers =
      receive do
        {:headers, ^ref, headers} -> headers
      end

    body_stream = Stream.resource(fn -> ref end, &receive_data/1, fn _ -> nil end)
    {status, headers, body_stream}
  end

  defp receive_data(ref) do
    receive do
      {:body, ^ref, data} -> {[data], ref}
      {:done, ^ref} -> {:halt, ref}
    end
  end
end
