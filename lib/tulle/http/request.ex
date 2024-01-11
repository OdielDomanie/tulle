defmodule Tulle.HTTP.Request do
  @moduledoc false

  @typedoc """
  A `Collectable` that writes to an HTTP request stream.

  Created with `Tulle.HTTP.request_collectable!/2`.
  When done sending, `Tulle.HTTP.close_request!/1` must be called to signal the EOF.
  """
  @opaque t :: %__MODULE__{client: GenServer.server(), ref: Mint.Types.request_ref(), info: any}

  @enforce_keys [:client, :ref]
  defstruct [:client, :ref, :info]

  @spec set_info(t, any) :: t
  @doc """
  Put arbitrary custom data that can be accessed with `get_info/1`
  """
  def set_info(request, info) do
    %__MODULE__{request | info: info}
  end

  @spec get_info(t) :: any
  @doc """
  Get the custom data that was put with `set_info/2`
  """
  def get_info(request) do
    request.info
  end
end
