defmodule Zystem.Application do
  use Application

  def start(_type, _args) do
    # allow the program to receive sigchld notifications
    case :os.type() do
      {:unix, _} ->
        :os.set_signal(:sigchld, :default)
      _ ->
        raise "Zystem is not supported at this time."
    end

    # start an empty supervisor (for now)
    # this might change into a dynamic supervisor in the future.
    Supervisor.start_link([], strategy: :one_for_one)
  end
end
