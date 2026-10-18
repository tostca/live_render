defmodule LiveRender.OpenUI.Error do
  @moduledoc """
  The OpenUI error object (language.md, section 8.3), ready to send back to the model.

  `source` is `:parser`, `:runtime`, `:query` or `:mutation`. `code` is one of the codes of
  section 8.2. `severity` is `:warning` only for errors the page renders through (today, the
  fallback `no-root`).
  """

  defstruct [
    :source,
    :code,
    :message,
    :statement_id,
    :component,
    :path,
    :tool_name,
    :hint,
    :severity
  ]

  @type source :: :parser | :runtime | :query | :mutation
  @type t :: %__MODULE__{
          source: source(),
          code: String.t(),
          message: String.t(),
          statement_id: String.t() | nil,
          component: String.t() | nil,
          path: String.t() | nil,
          tool_name: String.t() | nil,
          hint: String.t() | nil,
          severity: :warning | nil
        }

  @fatal_codes ["parse-failed", "parse-exception"]

  @doc "True when nothing renders because of this error."
  def fatal?(%__MODULE__{code: code}) when code in @fatal_codes, do: true
  def fatal?(%__MODULE__{code: "no-root", severity: nil}), do: true
  def fatal?(_), do: false

  @doc "The wire shape: a map with camelCase keys, leaving out nil fields."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = e) do
    [
      {"source", e.source && Atom.to_string(e.source)},
      {"code", e.code},
      {"statementId", e.statement_id},
      {"component", e.component},
      {"path", e.path},
      {"toolName", e.tool_name},
      {"message", e.message},
      {"hint", e.hint},
      {"severity", e.severity && Atom.to_string(e.severity)}
    ]
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
    |> Map.new()
  end

  defimpl Jason.Encoder do
    def encode(error, opts), do: Jason.Encode.map(LiveRender.OpenUI.Error.to_map(error), opts)
  end
end
