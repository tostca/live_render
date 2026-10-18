defmodule LiveRender.OpenUI.Element do
  @moduledoc """
  A component instance: the library component `type_name` with its positional arguments mapped to
  named `props`.

  Before evaluation, prop values may still hold AST nodes (tuples) for anything that depends on
  state or queries. After `LiveRender.OpenUI.Evaluator.evaluate_root/2` every prop is a plain
  value, another element, an `ActionPlan`, or a `Binding`.

  `statement_id` names the statement the element came from, or is nil for an inline call.
  """

  alias LiveRender.OpenUI.JS

  @enforce_keys [:type_name]
  defstruct type_name: nil, props: %{}, statement_id: nil, partial: false, dynamic: true

  @type t :: %__MODULE__{
          type_name: String.t(),
          props: %{String.t() => term()},
          statement_id: String.t() | nil,
          partial: boolean(),
          dynamic: boolean()
        }

  @doc "The fixture summary of an evaluated element (Appendix B): `{type, props}` without nulls."
  @spec summary(t()) :: map()
  def summary(%__MODULE__{type_name: type, props: props}) do
    props =
      props
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new(fn {k, v} -> {k, JS.to_json(v)} end)

    %{"type" => type, "props" => props}
  end
end

defmodule LiveRender.OpenUI.ActionPlan do
  @moduledoc """
  An `Action`: an ordered list of steps (language.md, section 6.3). Every action call evaluates to
  a plan, so `@ToAssistant("Hi")` is a plan of one step.

  Steps:

    * `{:run, statement_id, :query | :mutation}`
    * `{:continue_conversation, message, context}` where `context` is `:none` or any value
    * `{:open_url, url}`
    * `{:set, "$name", value_ast}`: the value is evaluated when the step runs
    * `{:reset, ["$a", "$b"]}`
    * `{:custom, name, params, param_order}`: a library action, delivered to the host

  Plans are structs, so no data the model writes can pose as one.
  """

  alias LiveRender.OpenUI.JS

  defstruct steps: []

  @type step ::
          {:run, String.t(), :query | :mutation}
          | {:continue_conversation, String.t(), term()}
          | {:open_url, String.t()}
          | {:set, String.t(), tuple()}
          | {:reset, [String.t()]}
          | {:custom, String.t(), map(), [String.t()]}

  @type t :: %__MODULE__{steps: [step()]}

  @doc "Plain JSON data for a plan, for logging and serialization."
  def summary(%__MODULE__{steps: steps}) do
    %{"steps" => Enum.map(steps, &step_json/1)}
  end

  defp step_json({:run, id, type}),
    do: %{"type" => "run", "statementId" => id, "refType" => to_string(type)}

  defp step_json({:continue_conversation, msg, :none}),
    do: %{"type" => "continue_conversation", "message" => msg}

  defp step_json({:continue_conversation, msg, ctx}),
    do: %{
      "type" => "continue_conversation",
      "message" => msg,
      "context" => JS.to_json(ctx)
    }

  defp step_json({:open_url, url}), do: %{"type" => "open_url", "url" => url}
  defp step_json({:set, target, _ast}), do: %{"type" => "set", "target" => target}
  defp step_json({:reset, targets}), do: %{"type" => "reset", "targets" => targets}

  defp step_json({:custom, name, params, _order}),
    do: %{"type" => name, "params" => JS.to_json(params)}
end

defmodule LiveRender.OpenUI.Binding do
  @moduledoc """
  A two-way binding: a `$variable` passed to a bindable prop (language.md, section 5.2). The
  component shows the variable's value and writes user changes back to `target`.

  `expr` is set only for the runtime form `$name = expression`, where the written value is
  `expression` evaluated with `$value` bound to what the user entered.
  """

  @enforce_keys [:target]
  defstruct [:target, expr: nil]

  @type t :: %__MODULE__{target: String.t(), expr: tuple() | nil}
end
