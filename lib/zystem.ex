defmodule Zystem do

  alias Zystem.Nif

  def cmd(command, args, opts \\ [])

  @spec cmd(binary(), [binary()], keyword()) ::
    {Collectable.t(), exit_status :: non_neg_integer()}
  @doc """

  A clone of System.cmd

  ```elixir
  iex> Zystem.cmd("echo", ["hello"])
  {"hello\n", 0}
  ```
  """
  def cmd(command, args, opts) do
    zig_opts = get_zig_opts(opts)

    command
    |> Nif.build(args, zig_opts)
    |> Nif.exec()

    results = collect_results()

    {results.stdout, results.retval}
    |> transform_collectible(Keyword.get(opts, :into))
  end

  @copy_opts [:env, :stdin, :stdout, :stderr]
  defp get_zig_opts(opts) do
    opts
    |> Enum.flat_map(fn
      {:cd, path} -> [cwd: path]
      {:stderr_to_stdout, true} -> [stdout: Pipe, stderr: :stdout]
      opt = {key, _} when key in @copy_opts -> [opt]
      _ -> []
    end)
  end

  defp transform_collectible({stdout, retval}, nil) do
    stdout_bin = stdout
    |> Enum.reverse
    |> IO.iodata_to_binary
    {stdout_bin, retval}
  end

  defp transform_collectible({stdout, retval}, collectible) do
    collected = stdout
    |> Enum.reverse
    |> Enum.into(collectible)
    {collected, retval}
  end

  def collect_results(so_far \\ %{stdout: [], stderr: []}) do
    receive do
      {:stdout, content} ->
        so_far
        |> append(:stdout, content)
        |> collect_results
      {:stderr, content} ->
        so_far
        |> append(:stderr, content)
        |> collect_results
      {:end, retval} ->
        Map.put(so_far, :retval, retval)
    end
  end

  defp append(so_far, key, content) when is_map_key(so_far, key) do
    # iolist it.
    %{so_far | key => [content | Map.fetch!(so_far, key)]}
  end

  defp append(so_far, key, content), do: Map.put(so_far, key, content)
end
