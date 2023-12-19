defmodule Tulle.Http.Request do
  @moduledoc false

  @typedoc """
  A `Collectable` that writes to an HTTP request stream.

  Created with `request_collectable/3`.
  When done sending, `close_request!/1` must be called to signal the EOF.
  """
  @opaque t :: %__MODULE__{client: GenServer.name(), ref: Mint.Types.request_ref(), info: any}

  @enforce_keys [:client, :ref]
  defstruct [:client, :ref, :info]
end
