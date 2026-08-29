defmodule FeoxDB.Error do
  @moduledoc """
  Raised by the bang (`!`) variants of `FeoxDB` functions when the
  underlying store returns an error.
  """

  defexception [:reason]

  @impl true
  def message(%__MODULE__{reason: reason}) do
    "FeoxDB operation failed: #{inspect(reason)}"
  end
end
