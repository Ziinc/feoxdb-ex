defmodule FeoxDB.CredoChecks.NoUnsafeAtomConversion do
  @moduledoc """
  Flags calls to `String.to_atom/1` and `:erlang.binary_to_term/1`.

  The VM keeps atoms for its lifetime. For input that names an existing
  atom, use `String.to_existing_atom/1`. It raises if the atom does not exist.

  When decoding external terms, use `:erlang.binary_to_term/2` with
  `[:safe]` to prevent the decoder from creating atoms. Validate the
  decoded term before using it.
  """

  @explanation [
    check: @moduledoc,
    params: []
  ]

  use Credo.Check, base_priority: :high, category: :security, explanations: @explanation

  alias Credo.Code

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)

    Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
  end

  defp traverse(
         {{:., _, [{:__aliases__, alias_meta, [:String]}, :to_atom]}, _, [_arg]} = ast,
         issues,
         issue_meta
       ) do
    {ast, [issue_for(issue_meta, alias_meta, "String.to_atom") | issues]}
  end

  defp traverse(
         {{:., meta, [:erlang, :binary_to_term]}, _, [_arg]} = ast,
         issues,
         issue_meta
       ) do
    # The `:erlang` atom in `:erlang.binary_to_term(...)` carries no
    # metadata of its own, so we can't point at its exact column here (and
    # deriving it from the dot's column would be brittle) - report the line
    # only.
    {ast, [issue_for(issue_meta, [line: meta[:line]], ":erlang.binary_to_term") | issues]}
  end

  defp traverse(ast, issues, _issue_meta) do
    {ast, issues}
  end

  defp issue_for(issue_meta, meta, trigger) do
    format_issue(
      issue_meta,
      message:
        "Avoid #{trigger}/1 on external input: it can exhaust the atom table or " <>
          "construct unsafe terms. Use #{safe_alternative(trigger)} instead.",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end

  defp safe_alternative("String.to_atom"), do: "String.to_existing_atom/1"
  defp safe_alternative(_), do: ":erlang.binary_to_term/2 with the `:safe` option"
end
