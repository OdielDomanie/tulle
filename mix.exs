defmodule Tulle.MixProject do
  use Mix.Project

  @version "0.6.3"

  def project do
    [
      app: :tulle,
      description: "Process pool based HTTP1/2 and Websocket client",
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      package: package(),
      deps: deps(),
      docs: [
        source_url: "https://github.com/OdielDomanie/tulle",
        source_ref: "v#{@version}"
      ]
    ]
  end

  defp package do
    [
      # These are the default files included in the package
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/OdielDomanie/tulle"}
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
      {:deep_merge, "~> 1.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 0.6", only: [:test]},
      {:bandit, "~> 1.0", only: [:test]},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end
end
