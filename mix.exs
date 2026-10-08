defmodule AppointmentReferralLink.MixProject do
  use Mix.Project

  def project do
    [
      app: :appointment_referral_link,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
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

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:rule_match, github: "agoodway/rule_match"},
      {:patient_matching, github: "agoodway/patient_matching"},
      {:ortex, "~> 0.1.10", optional: true},
      {:stream_data, "~> 1.1", only: :test},
      {:postgrex, "~> 0.22", only: :test}
    ]
  end
end
