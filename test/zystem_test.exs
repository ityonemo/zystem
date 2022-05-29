defmodule ZystemTest do
  use ExUnit.Case
  doctest Zystem

  test "greets the world" do
    assert Zystem.hello() == :world
  end
end
