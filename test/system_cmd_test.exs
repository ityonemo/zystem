defmodule ZystemTest.SystemCmdTest do
  use ExUnit.Case, async: true

  # this module tests to make sure the features of Zystem.cmd/3 match System.cmd/3

  defmacro assert_both(what, cmd, params, options \\ []) do
    quote do
      assert unquote(what) = System.cmd(unquote(cmd), unquote(params), unquote(options))
      assert unquote(what) = Zystem.cmd(unquote(cmd), unquote(params), unquote(options))
    end
  end

  test "error values are returned" do
    assert {"", 1} == System.cmd("false", [])
    assert {"", 1} == Zystem.cmd("false", [])
  end

  test "into option" do
    assert {["hello world\n"], 0} == System.cmd("echo", ["hello", "world"], into: [])
    assert {["hello world\n"], 0} == Zystem.cmd("echo", ["hello", "world"], into: [])
  end

  test "cd option" do
    assert {"example\n", 0} == System.cmd("dir", [], cd: "test/assets/dir")
    assert {"example\n", 0} == Zystem.cmd("dir", [], cd: "test/assets/dir")
  end
end
