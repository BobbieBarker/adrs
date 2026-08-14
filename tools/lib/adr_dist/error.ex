defmodule AdrDist.Error do
  @moduledoc """
  Structured, actionable error returned at ADR distribution boundaries.
  """

  @enforce_keys [:code, :message]
  defstruct [:code, :message, :path, :line, details: nil]

  @type t :: %__MODULE__{
          code: atom(),
          message: String.t(),
          path: String.t() | nil,
          line: pos_integer() | nil,
          details: term()
        }

  @spec new(atom(), String.t(), keyword()) :: t()
  def new(code, message, options \\ []) when is_atom(code) and is_binary(message) do
    %__MODULE__{
      code: code,
      message: message,
      path: Keyword.get(options, :path),
      line: Keyword.get(options, :line),
      details: Keyword.get(options, :details)
    }
  end

  @spec format(t()) :: String.t()
  def format(%__MODULE__{} = error) do
    location =
      cond do
        error.path && error.line -> "#{error.path}:#{error.line}: "
        error.path -> "#{error.path}: "
        true -> ""
      end

    details = if is_nil(error.details), do: "", else: " (#{inspect(error.details)})"
    location <> error.message <> details
  end
end
