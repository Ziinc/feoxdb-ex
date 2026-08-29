%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/", "mix.exs"],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/native/"]
      },
      strict: true,
      checks: %{
        enabled: [
          {Credo.Check.Consistency.ExceptionNames, []},
          {Credo.Check.Consistency.LineEndings, []},
          {Credo.Check.Consistency.ParameterPatternMatching, []},
          {Credo.Check.Consistency.SpaceAroundOperators, []},
          {Credo.Check.Consistency.SpaceInParentheses, []},
          {Credo.Check.Consistency.TabsOrSpaces, []},

          {Credo.Check.Design.AliasUsage,
           [priority: :low, if_nested_deeper_than: 2, if_called_more_often_than: 0]},

          {Credo.Check.Readability.ModuleDoc, []},
          {Credo.Check.Readability.ModuleNames, []},
          {Credo.Check.Readability.ParenthesesOnZeroArityDefs, []},
          {Credo.Check.Readability.PredicateFunctionNames, []},
          {Credo.Check.Readability.MaxLineLength, [priority: :low, max_length: 120]},

          {Credo.Check.Refactor.CyclomaticComplexity, []},
          {Credo.Check.Refactor.Nesting, []},

          {Credo.Check.Warning.IExPry, []},
          {Credo.Check.Warning.IoInspect, []}
        ]
      }
    }
  ]
}
