defmodule FeoxDB.CredoChecks.NativeCallValidationTest do
  use Credo.Test.Case

  alias FeoxDB.CredoChecks.NativeCallValidation

  test "does not report a function guarded via a head guard clause" do
    """
    defmodule FeoxDB do
      def get(store, key) when is_binary(key) do
        Native.get(store, key)
      end
    end
    """
    |> to_source_file("lib/feox_db.ex")
    |> run_check(NativeCallValidation)
    |> refute_issues()
  end

  test "does not report a function that wraps the Native call in a case" do
    """
    defmodule FeoxDB do
      def flush(store) do
        case Native.flush(store) do
          {:error, reason} -> {:error, reason}
          :ok -> :ok
        end
      end
    end
    """
    |> to_source_file("lib/feox_db.ex")
    |> run_check(NativeCallValidation)
    |> refute_issues()
  end

  test "does not report a function that validates via with" do
    """
    defmodule FeoxDB do
      def insert(store, key, value) do
        with true <- is_binary(key) do
          Native.insert(store, key, value)
        end
      end
    end
    """
    |> to_source_file("lib/feox_db.ex")
    |> run_check(NativeCallValidation)
    |> refute_issues()
  end

  test "does not report functions outside of lib/feox_db.ex" do
    """
    defmodule FeoxDB.Other do
      def unsafe(store, key) do
        Native.get(store, key)
      end
    end
    """
    |> to_source_file("lib/feox_db/other.ex")
    |> run_check(NativeCallValidation)
    |> refute_issues()
  end

  test "reports a public function calling Native without any guard, case, or with" do
    """
    defmodule FeoxDB do
      def unsafe(store, key) do
        Native.get(store, key)
      end
    end
    """
    |> to_source_file("lib/feox_db.ex")
    |> run_check(NativeCallValidation)
    |> assert_issue(fn issue -> assert issue.trigger == "unsafe" end)
  end
end
