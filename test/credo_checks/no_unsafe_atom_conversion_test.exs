defmodule FeoxDB.CredoChecks.NoUnsafeAtomConversionTest do
  use Credo.Test.Case

  alias FeoxDB.CredoChecks.NoUnsafeAtomConversion

  test "does not report String.to_existing_atom/1" do
    """
    defmodule CredoSampleModule do
      def to_atom(binary) do
        String.to_existing_atom(binary)
      end
    end
    """
    |> to_source_file()
    |> run_check(NoUnsafeAtomConversion)
    |> refute_issues()
  end

  test "does not report :erlang.binary_to_term/2 with the :safe option" do
    """
    defmodule CredoSampleModule do
      def deserialize(binary) do
        :erlang.binary_to_term(binary, [:safe])
      end
    end
    """
    |> to_source_file()
    |> run_check(NoUnsafeAtomConversion)
    |> refute_issues()
  end

  test "reports String.to_atom/1" do
    """
    defmodule CredoSampleModule do
      def to_atom(binary) do
        String.to_atom(binary)
      end
    end
    """
    |> to_source_file()
    |> run_check(NoUnsafeAtomConversion)
    |> assert_issue(fn issue -> assert issue.trigger == "String.to_atom" end)
  end

  test "reports :erlang.binary_to_term/1" do
    """
    defmodule CredoSampleModule do
      def deserialize(binary) do
        :erlang.binary_to_term(binary)
      end
    end
    """
    |> to_source_file()
    |> run_check(NoUnsafeAtomConversion)
    |> assert_issue(fn issue -> assert issue.trigger == ":erlang.binary_to_term" end)
  end
end
