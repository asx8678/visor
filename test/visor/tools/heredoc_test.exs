defmodule Visor.Tools.HeredocTest do
  # Not async: one test counts the VM's atoms.
  use ExUnit.Case, async: false

  alias Visor.Tools.Heredoc

  # The string a repaired script binds to `a`.
  defp a(code) do
    assert repaired = Heredoc.repair(code), "not repaired:\n#{code}"
    {_value, binding} = Code.eval_string(repaired)
    binding[:a]
  end

  # The shapes live runs wrote, each cut from a script that failed.
  test "reads a heredoc whose text starts on its opening line as its text, exactly" do
    # One line, closed on it, as Python's """...""".
    assert a(~S'a = ~S"""  test "transfers money" do"""') == ~S'  test "transfers money" do'

    # Closed after text on a later line: no newline at its end.
    assert a(~S'''
           a = ~S"""  @doc "Takes amount."
             def withdraw(l, a, n) when n > 0 do"""; b = 1
           ''') == "  @doc \"Takes amount.\"\n  def withdraw(l, a, n) when n > 0 do"

    # ~S''' around text that holds """ and every bracket: a heredoc then,
    # without its last newline.
    code =
      Enum.join(
        [
          ~S(a = ~S'''  @doc """),
          ~S"  Sums {a, b} [x] (y) <z> |w| /v/",
          ~S(  """),
          ~S(  def f do''')
        ],
        "\n"
      )

    assert a(code) == "  @doc \"\"\"\n  Sums {a, b} [x] (y) <z> |w| /v/\n  \"\"\"\n  def f do"
  end

  test "moves the text to its own line when the closing starts a later line" do
    assert a(~s(a = """first\nsecond\n"""\n)) == "first\nsecond\n"
  end

  test "reads a plain one as a string, with its interpolation" do
    assert a(~S'n = 2; a = """n is #{n}"""') == "n is 2"
    assert a(~S"a = '''it's'''") == "it's"
  end

  test "puts right each one in a script, and nothing else" do
    code = ~S'V.edit("a.ex", ~S"""old "x" """, ~S"""new "y" """)'
    assert Heredoc.repair(code) == ~S'V.edit("a.ex", ~S[old "x" ], ~S[new "y" ])'

    # A heredoc written right, holding Python's triple quotes, is fine as it is.
    assert Heredoc.repair(~s|V.sh(~S"""\npython3 -c 's = """x"""'\n""")|) == nil
    # Without a closing, or in another sigil, it is left to its error.
    assert Heredoc.repair(~S'a = """text') == nil
    assert Heredoc.repair(~S'a = ~r"""ab"""') == nil
  end

  test "parses the model's code without making an atom" do
    name = "zz_heredoc_#{System.unique_integer([:positive])}"
    atoms = :erlang.system_info(:atom_count)
    assert Heredoc.repair(~s(#{name} = ~S"""x"""\n#{name}_b = :#{name}_c)) =~ "~S[x]"
    assert :erlang.system_info(:atom_count) == atoms
  end
end
