defmodule Tulle.MixProject do
  use Mix.Project

  def project do
    [
      app: :tulle,
      version: "0.5.1",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:mint, "~> 1.0"},
      {:mint_web_socket, "~> 1.0.3"},
      {:websock, "~> 0.5.3"},
      {:deep_merge, "~> 1.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 0.6", only: [:test]},
      {:bandit, "~> 1.0", only: [:test]},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
