defmodule ZystemTest.SystemCmdTest do
  use ExUnit.Case, async: true

  # this module tests to make sure the features of Zystem.cmd/3 match System.cmd/3

  test "error values are returned" do
    assert {"", 1} == Zystem.cmd("false", [])
  end

  test "into option" do
    assert {["hello world\n"], 0} == Zystem.cmd("echo", ["hello", "world"], into: [])
  end
end
