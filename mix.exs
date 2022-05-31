defmodule Zystem.MixProject do
  use Mix.Project

  def project do
    [
      app: :zystem,
      version: "0.1.0",
      elixir: "~> 1.12",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Zystem.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:zigler, "~> 0.9.1", runtime: false}
    ]
  end
end
