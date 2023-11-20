defmodule Tulle.Http1.Request do
  @moduledoc false

  alias Tulle.Http1.Client

  @typedoc """
  A `Collectable` that writes to an HTTP request stream.

  Created with `request_collectable/3`.
  When done sending, `close_request!/1` must be called to signal the EOF.
  """
  @opaque t :: %__MODULE__{client: Client.t(), ref: Mint.Types.request_ref()}

  @enforce_keys [:client, :ref]
  defstruct [:client, :ref]
end
