defmodule Tracker.Mixfile do
  use Mix.Project

  def project do
    [app: :tracker,
     version: "0.0.1",
     elixir: "~> 1.2-rc",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     deps: deps]
  end

  def application do
    [applications: [:logger, :gproc, :cowboy, :plug]]
  end

  defp deps do
    [{:cowboy, "~> 1.0.0"},
     {:plug, "~> 1.0"},
     {:gproc, "~> 0.5.0"},
     {:uuid, "~> 1.1.1"},
     {:bencode, "~> 0.2.0"}]
  end
end
