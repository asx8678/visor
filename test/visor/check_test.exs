defmodule Visor.CheckTest do
  use ExUnit.Case, async: false

  alias Visor.{Check, Code, Feedback}

  # Output of `mix test --seed 0` on a small project, captured with
  # Elixir 1.20.
  @fixtures "test/support/fixtures/check"

  defp parse(name, exit), do: Check.parse(File.read!(Path.join(@fixtures, name <> ".txt")), exit)

  describe "parse/2 and render/4" do
    test "lists failures in file order, without timings or progress" do
      check = parse("failures", 2)

      assert %{status: :failed, tests: 5, passed: 1, failed: 4, skipped: 1} = check

      assert Check.render(check, nil, ["lib/checkdemo.ex"], "r1") == """
             check failed: 4 of 5 tests, 1 skipped
             failures:
               test/checkdemo_test.exs:9 "adds wrongly" (CheckdemoTest)
                 Assertion with == failed
                 code:  assert Checkdemo.add(1, 2) == 4
                 left:  3
                 right: 4
                 at test/checkdemo_test.exs:10: (test)
               test/checkdemo_test.exs:13 "raises" (CheckdemoTest)
                 ** (RuntimeError) boom
                 code: Checkdemo.boom()
                 at (checkdemo 0.1.0) lib/checkdemo.ex:9: Checkdemo.boom/0
               test/checkdemo_test.exs:17 "matches text" (CheckdemoTest)
                 Assertion with =~ failed
                 code:  assert "Cancelled." =~ "not found"
                 left:  "Cancelled."
                 right: "not found"
                 at test/checkdemo_test.exs:18: (test)
               test/other_test.exs:4 "map keys" (Checkdemo.OtherTest)
                 Assertion with == failed
                 code:  assert %{a: 1, b: 2} == %{a: 1, b: 3}
                 left:  %{a: 1, b: 2}
                 right: %{a: 1, b: 3}
                 at test/other_test.exs:5: (test)
             warnings in files this session changed:
               lib/checkdemo.ex:5: variable "y" is unused (if the variable is not meant to be \
             used, prefix it with an underscore)
             full output: r1\
             """
    end

    test "shows compile errors, and only the warnings in files the session changed" do
      check = parse("compile_error", 1)
      assert check.status == :compile_error

      assert Check.render(check, nil, [], "r2") == """
             check failed to compile lib/checkdemo.ex; the tests did not run
             errors:
               lib/checkdemo.ex:2: undefined variable "c"
             2 warnings, none in files this session changed
             full output: r2\
             """
    end

    test "shows why a compile stopped when it says more than the errors" do
      assert Check.render(parse("syntax_error", 1)) == """
             check failed to compile lib/checkdemo.ex; the tests did not run
             errors:
               ** (TokenMissingError) token missing on lib/checkdemo.ex:6:4:
               lib/checkdemo.ex:6: missing terminator: end\
             """

      assert Check.render(parse("test_syntax", 1)) =~
               ~r/\Acheck failed to compile test\/broken_test.exs; the tests did not run\n/
    end

    test "reports a failed setup_all" do
      check = parse("invalid", 2)
      assert %{status: :failed, tests: 0, invalid: 1, failed: 0} = check

      assert Check.render(check) == """
             check failed: 0 tests, 1 invalid
             failures:
               Checkdemo.SetupTest: failure on setup_all callback, all tests have been invalidated
                 ** (RuntimeError) no database
                 at test/setup_test.exs:5: Checkdemo.SetupTest.__ex_unit_setup_all_0/1
             2 warnings, none in files this session changed\
             """
    end

    test "reads passing runs" do
      assert Check.render(parse("all_pass", 0)) == "check passed: 3 tests"

      assert Check.render(parse("pass", 0), nil, ["lib/other.ex"]) ==
               "check passed: 1 test, 3 excluded\n1 warning, none in files this session changed"
    end

    test "says what changed since the last check of the same tests" do
      failures = parse("failures", 2)
      [first | _] = failures.failures
      earlier = %{failures | failures: [%{first | name: "old one"}, List.last(failures.failures)]}

      rendered = Check.render(failures, earlier)

      assert rendered =~
               "since the last check: 1 fixed, 3 new, 1 still failing\n" <>
                 ~s|fixed: "old one" (CheckdemoTest)\nfailures:\n|

      assert rendered =~ ~s|  test/checkdemo_test.exs:9 "adds wrongly" (CheckdemoTest), new\n|
      assert rendered =~ ~s|  test/other_test.exs:4 "map keys" (Checkdemo.OtherTest)\n|

      assert Check.render(parse("all_pass", 0), failures) ==
               """
               check passed: 3 tests
               since the last check: 4 fixed, 0 new, 0 still failing
               fixed: "map keys" (Checkdemo.OtherTest), "adds wrongly" (CheckdemoTest), \
               "matches text" (CheckdemoTest), "raises" (CheckdemoTest)\
               """

      # A compile error ran no tests, so there is nothing to compare.
      refute Check.render(parse("all_pass", 0), parse("compile_error", 1)) =~ "since"
    end

    test "reads the older summary line" do
      check = Check.parse("..F\n\nFinished in 0.1 seconds\n1 doctest, 3 tests, 1 failure\n", 2)
      assert %{status: :failed, tests: 4, passed: 3, failed: 1} = check
    end

    test "shows the end of a run it can't read" do
      output = "Compiling 1 file (.ex)\n** (Mix) Could not start application demo: boom\n"
      check = Check.parse(output, 1)

      assert check.status == :error

      assert Check.render(check) == """
             check failed: mix test exited with status 1
             output ends with:
               ** (Mix) Could not start application demo: boom\
             """
    end

    test "returns a small map to the script" do
      assert %{
               status: :failed,
               tests: 5,
               failed: 4,
               errors: [],
               failures: [
                 %{test: "adds wrongly", module: "CheckdemoTest", file: "test/checkdemo_test.exs"}
                 | _
               ]
             } = Check.result(parse("failures", 2))

      assert %{status: :compile_error, errors: [%{file: "lib/checkdemo.ex", line: 2}]} =
               Check.result(parse("compile_error", 1))
    end
  end

  describe "V.check/1" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      previous = Application.get_env(:visor, :workspace)
      Application.put_env(:visor, :workspace, tmp_dir)
      on_exit(fn -> Application.put_env(:visor, :workspace, previous) end)

      id = "check-test-#{System.unique_integer([:positive])}"
      start_supervised!({Feedback, id: id})
      %{context: %{session: id, call_id: "c1"}}
    end

    test "refuses paths that aren't test paths, and projects without mix.exs", %{context: context} do
      assert {:error, message} = Code.run(~S|V.check()|, context)
      assert message =~ "V.check needs a Mix project"

      File.write!(Path.join(Visor.Workspace.root(), "mix.exs"), "")
      assert {:error, message} = Code.run(~S|V.check("test; rm -rf /")|, context)
      assert message =~ "V.check takes a test path"
    end

    test "waits for another check of the same project to end", %{
      tmp_dir: tmp_dir,
      context: context
    } do
      File.write!(Path.join(tmp_dir, "mix.exs"), "")
      key = {:check, Path.expand(tmp_dir)}
      test = self()

      other =
        spawn(fn ->
          Visor.Lock.hold(key, fn ->
            send(test, :checking)
            receive do: (:done -> :ok)
          end)
        end)

      assert_receive :checking
      check = Task.async(fn -> Code.run(~S|V.check()|, context) end)
      wait_until_queued(key)
      assert Task.yield(check, 0) == nil

      send(other, :done)
      assert {:ok, result} = Task.await(check, 60_000)
      assert result =~ "check failed"
    end

    @tag timeout: 180_000
    test "an attempt puts every file back when its check fails, and keeps them when it passes",
         %{tmp_dir: tmp_dir, context: context} do
      write_project(tmp_dir)
      original = File.read!(Path.join(tmp_dir, "lib/demo.ex"))

      failing = ~S"""
      V.attempt(fn ->
        V.edit("lib/demo.ex", "a + b", "a - b")
        V.write("lib/extra.ex", "defmodule Extra do\nend\n")
      end, check: "test/demo_test.exs")
      """

      assert {:ok, text} = Code.run(failing, context)
      assert text =~ "reverted: lib/demo.ex, lib/extra.ex (the attempt's check failed)"
      refute text =~ "changed:"
      assert text =~ "status: :reverted"
      assert File.read!(Path.join(tmp_dir, "lib/demo.ex")) == original
      refute File.exists?(Path.join(tmp_dir, "lib/extra.ex"))

      # The check of the tree that was put back isn't what the next one is
      # compared with.
      assert {:ok, text} = Code.run(~S|V.check("test/demo_test.exs")|, context)
      refute text =~ "fixed"

      passing = ~S|V.attempt(fn -> V.edit("lib/demo.ex", "a + b", "b + a") end).status|
      assert {:ok, text} = Code.run(passing, context)
      assert text =~ "=> :kept"
      assert File.read!(Path.join(tmp_dir, "lib/demo.ex")) =~ "b + a"
    end

    test "an attempt whose call fails puts its files back, and stops the script",
         %{tmp_dir: tmp_dir, context: context} do
      write_project(tmp_dir)
      original = File.read!(Path.join(tmp_dir, "lib/demo.ex"))

      script = ~S"""
      V.attempt(fn ->
        V.edit("lib/demo.ex", "a + b", "a * b")
        V.edit("lib/demo.ex", "not there", "x")
      end)
      """

      assert {:error, text} = Code.run(script, context)
      assert text =~ "failed at call 1: V.attempt"
      assert text =~ "V.attempt put 1 file back: The text to replace was not found"
      assert text =~ "reverted: lib/demo.ex (the attempt failed)"
      refute text =~ "changed:"
      assert File.read!(Path.join(tmp_dir, "lib/demo.ex")) == original

      assert {:error, text} = Code.run(~S|V.attempt(fn -> V.attempt(fn -> 1 end) end)|, context)
      assert text =~ "V.attempt can't run inside another."

      script = ~S|V.attempt(fn -> V.sh("sleep 1", background: true) end)|
      assert {:error, text} = Code.run(script, context)
      assert text =~ "A background job can't start inside V.attempt"
    end

    # Runs mix test in a small project of its own, never in Visor.
    @tag timeout: 180_000
    test "checks a change, then says what the fix fixed", %{tmp_dir: tmp_dir, context: context} do
      write_project(tmp_dir)

      script = ~S"""
      V.edit("lib/demo.ex", "a + b", "a - b")
      V.check()
      """

      assert {:ok, missing} = Code.run(~S|V.check("test/missing_test.exs")|, context)

      assert missing == """
             ok: 1 call
             check failed: mix test exited with status 1
             output ends with:
               Paths given to "mix test" did not match any directory/file: test/missing_test.exs
             full output: r1\
             """

      assert {:ok, broken} = Code.run(script, context)

      assert broken =~ """
             ok: 2 calls
             changed: lib/demo.ex (edit)
             check failed: 1 of 2 tests
             failures:
               test/demo_test.exs:4 "adds" (DemoTest)
                 Assertion with == failed
                 code:  assert Demo.add(1, 2) == 3
                 left:  -1
                 right: 3
                 at test/demo_test.exs:5: (test)
             full output: r\
             """

      refute broken =~ "=>"

      script = ~S"""
      V.edit("lib/demo.ex", "a - b", "a + b")
      V.check().status
      """

      assert {:ok, fixed} = Code.run(script, context)

      assert fixed == """
             ok: 2 calls
             changed: lib/demo.ex (edit)
             check passed: 2 tests
             since the last check: 1 fixed, 0 new, 0 still failing
             fixed: "adds" (DemoTest)
             => :ok\
             """
    end
  end

  # Returns once a process is waiting for `key`, or fails after 5 s.
  defp wait_until_queued(key, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    waiting =
      case :sys.get_state(Visor.Lock) do
        %{^key => {_holder, _ref, waiting}} -> :queue.len(waiting)
        _ -> 0
      end

    cond do
      waiting > 0 ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("nothing waited for #{inspect(key)}")

      true ->
        wait_until_queued(key, deadline)
    end
  end

  defp write_project(dir) do
    files = %{
      "mix.exs" => """
      defmodule Demo.MixProject do
        use Mix.Project
        def project, do: [app: :demo, version: "0.1.0", deps: []]
      end
      """,
      "lib/demo.ex" => """
      defmodule Demo do
        def add(a, b), do: a + b
      end
      """,
      "test/test_helper.exs" => "ExUnit.start()\n",
      "test/demo_test.exs" => """
      defmodule DemoTest do
        use ExUnit.Case

        test "adds" do
          assert Demo.add(1, 2) == 3
        end

        test "is a module" do
          assert is_atom(Demo)
        end
      end
      """
    }

    for {path, contents} <- files do
      File.mkdir_p!(Path.dirname(Path.join(dir, path)))
      File.write!(Path.join(dir, path), contents)
    end
  end
end
