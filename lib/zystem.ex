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
  def cmd(command, args, _opts) do
    command
    |> Nif.build(args)
    |> Nif.exec

    receive do
      any -> any
    end
  end
end
