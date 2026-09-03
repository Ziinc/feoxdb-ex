defmodule FeoxDB.CredoChecks.NativeCallValidation do
  @moduledoc """
  Flags public `FeoxDB` API functions that call into `FeoxDB.Native` without
  any visible validation or control-flow guard beforehand.

  `FeoxDB.Native` is the Rustler NIF boundary: every argument that crosses it
  ends up read directly by Rust code. Public functions in `lib/feox_db.ex`
  are expected to validate or otherwise narrow their inputs (via a guard
  clause such as `when is_binary(key)`, or a `with`/`case` construct) before
  handing anything to `Native`, so that obviously-wrong input is rejected in
  Elixir with a friendly error instead of tripping an assertion (or worse)
  on the Rust side.

  ## Heuristic, not semantic analysis

  Credo checks operate on the AST, not on typed/semantic information, so
  this check is intentionally a coarse heuristic: a function "passes" if it
  contains *any* of the following anywhere in its definition, in addition
  to a call to `Native.<something>`/`FeoxDB.Native.<something>`:

    * a guard clause on the function head (a `when ...` clause), or
    * a `case` expression, or
    * a `with` expression

  Known limitations:

    * **False negatives**: a function could contain a `case`/`with`/guard
      that has nothing to do with validating the arguments passed to
      `Native` (e.g. a `case` on an unrelated value) and this check would
      still consider it "guarded". It cannot verify that the guard/branch
      actually narrows the values reaching `Native`.
    * **False positives**: a function that legitimately needs no validation
      (e.g. it forwards an already-validated value, or takes no
      user-controlled arguments) but doesn't happen to use `case`/`with`/a
      guard will still be flagged. To keep this from firing on the store
      handle alone, functions that take a single argument (assumed to be
      just the opaque `store` reference, e.g. `size/1`, `stats/1`) are
      skipped entirely, since there is no additional caller-supplied value
      to validate.

  Given these limitations, treat findings from this check as a prompt to
  double-check the function by hand, not as an automatic proof of a bug.
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
