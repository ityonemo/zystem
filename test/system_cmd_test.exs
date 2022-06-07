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
    assert_both({"", 1}, "false", [])
  end

  test "into option" do
    assert_both({["hello world\n"], 0}, "echo", ["hello", "world"], into: [])
  end

  test "cd option" do
    assert_both({"example\n", 0}, "dir", [], cd: "test/assets/dir")
  end

  # TODO: obtain this from zigler on 0.10.0
  @zig_path (case :os.type() do
    {:unix, :linux} ->
      Path.absname("deps/zigler/zig/zig-linux-x86_64-0.9.1/zig")
    {:unix, :darwin} ->
      Path.absname("deps/zigler/zig/zig-macos-x86_64-0.9.1/zig")
    end)

  test "env option" do
    path = Path.join(System.tmp_dir!(), "zystem-tests")
    # use zig to build the test asset.
    Zystem.cmd(@zig_path, ["build-exe", "test/assets/test-env.zig", "--cache-dir", path])
    File.rename!("test-env", "test-env.exe")

    # try building the file
    assert_both({"bar", 0}, Path.absname("test-env.exe"), ["foo"], env: [{"foo", "bar"}])
  end

  test "stderr_to_stdout option" do
    path = Path.join(System.tmp_dir!(), "zystem-tests")
    # use zig to build the test asset.
    Zystem.cmd(@zig_path, ["build-exe", "test/assets/test-stderr_to_stdout.zig", "--cache-dir", path])
    File.rename!("test-stderr_to_stdout", "test-stderr_to_stdout.exe")

    # try building the file
    assert_both({"stderr\nstdout\n", 0}, Path.absname("test-stderr_to_stdout.exe"), [], stderr_to_stdout: true)
  end
end
