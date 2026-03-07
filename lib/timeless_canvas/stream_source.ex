defmodule TimelessCanvas.StreamSource do
  @moduledoc """
  Behaviour for log/trace stream backends.
  Implementations subscribe to a stream and forward entries to the caller process.
  """

  @callback subscribe(opts :: keyword()) :: :ok

  @callback query(filters :: keyword()) ::
              {:ok, %{entries: [map()]}} | {:error, term()}

  @optional_callbacks [query: 1]
end
