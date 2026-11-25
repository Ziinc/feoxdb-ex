defmodule FeoxDB.Error do
  @moduledoc """
  Exception for store errors. The `reason` field contains the error atom.

  Functions such as `FeoxDB.get!/2` raise this exception on failure.
  """

  defexception [:reason]

  @impl true
  def message(%__MODULE__{reason: reason}) do
    "FeoxDB operation failed: #{inspect(reason)}"
  end
end
