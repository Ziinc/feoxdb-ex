defmodule FeoxDB.CredoChecks.NativeCallValidation do
  @moduledoc """
  Checks public functions in `lib/feox_db.ex` that call the native binding.

  The check looks for a guard on the function head, a type check such as
  `is_binary/1`, or a `case` or `with` expression in the body. It skips
  single-argument functions such as `size/1`, which take only a store handle.

  Review the arguments at the native call site. An unrelated guard can
  hide a missing check. A helper can validate an argument without using
  a construct the check recognizes.
  """

  @explanation [
    check: @moduledoc,
    params: []
  ]

  use Credo.Check, base_priority: :normal, category: :warning, explanations: @explanation

  alias Credo.Code

  @guard_functions ~w(
    is_atom is_binary is_boolean is_float is_function is_integer is_list
    is_map is_nil is_number is_pid is_reference is_tuple
  )a

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    if relevant_file?(source_file) do
      issue_meta = IssueMeta.for(source_file, params)

      source_file
      |> Code.ast()
      |> find_def_clauses()
      |> Enum.reject(&store_only_arity?/1)
      |> Enum.filter(&calls_native?/1)
      |> Enum.reject(&validated?/1)
      |> Enum.map(&issue_for(&1, issue_meta))
    else
      []
    end
  end

  # This check specifically guards the public API surface defined in
  # `lib/feox_db.ex`, which is the only module expected to call
  # `FeoxDB.Native` after validating its arguments.
  defp relevant_file?(source_file) do
    String.ends_with?(source_file.filename, "lib/feox_db.ex")
  end

  defp find_def_clauses(ast) do
    {_ast, clauses} =
      Macro.prewalk(ast, [], fn
        {:def, _, [_head, _body]} = node, acc -> {node, [node | acc]}
        node, acc -> {node, acc}
      end)

    Enum.reverse(clauses)
  end

  # A function that only accepts the opaque `store` reference (arity 1) has
  # no additional caller-supplied value that could need validating.
  defp store_only_arity?({:def, _, [head, _body]}) do
    arity(head) == 1
  end

  defp arity({:when, _, [call | _guard]}), do: arity(call)
  defp arity({_name, _, args}) when is_list(args), do: length(args)
  defp arity(_), do: 0

  defp calls_native?({:def, _, [_head, body]}) do
    contains?(body, &native_call?/1)
  end

  defp native_call?({{:., _, [{:__aliases__, _, aliases}, _fun]}, _, _args}) do
    List.last(aliases) == :Native
  end

  defp native_call?(_), do: false

  defp validated?({:def, _, [head, body]}) do
    head_has_guard?(head) or contains?(body, &validation_construct?/1)
  end

  defp head_has_guard?({:when, _, _}), do: true
  defp head_has_guard?(_), do: false

  defp validation_construct?({:case, _, _}), do: true
  defp validation_construct?({:with, _, _}), do: true
  defp validation_construct?({fun, _, args}) when is_list(args), do: fun in @guard_functions
  defp validation_construct?(_), do: false

  defp contains?(ast, matcher) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn node, acc -> {node, acc or matcher.(node)} end)

    found?
  end

  defp issue_for({:def, meta, [head, _body]}, issue_meta) do
    {name, name_meta} = function_name_and_meta(head)

    format_issue(
      issue_meta,
      message:
        "Public function `#{name}` calls FeoxDB.Native without an apparent " <>
          "guard clause, `case`, or `with` validating its input first.",
      trigger: to_string(name),
      line_no: name_meta[:line] || meta[:line],
      column: name_meta[:column]
    )
  end

  defp function_name_and_meta({:when, _, [call | _guard]}), do: function_name_and_meta(call)
  defp function_name_and_meta({name, meta, _args}), do: {name, meta}
end
