defmodule AdrDist.Adr do
  @moduledoc """
  A source ADR joined with its domain manifest metadata and parsed Markdown.
  """

  alias AdrDist.Markdown.Document

  @enforce_keys [
    :id,
    :domain,
    :file,
    :source_path,
    :title,
    :description,
    :applies_to,
    :raw,
    :body,
    :frontmatter,
    :document
  ]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: pos_integer(),
          domain: String.t(),
          file: String.t(),
          source_path: String.t(),
          title: String.t(),
          description: String.t(),
          applies_to: map(),
          raw: String.t(),
          body: String.t(),
          frontmatter: map(),
          document: Document.t()
        }

  @spec stable_id(t()) :: String.t()
  def stable_id(%__MODULE__{domain: domain, id: id}) do
    "#{domain}:adr-#{pad(id, 3)}"
  end

  @spec rule_id(t(), pos_integer()) :: String.t()
  def rule_id(%__MODULE__{} = adr, rule_number) do
    "#{stable_id(adr)}:rule-#{pad(rule_number, 2)}"
  end

  defp pad(value, width) do
    value
    |> Integer.to_string()
    |> String.pad_leading(width, "0")
  end
end
