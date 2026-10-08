defmodule AppointmentReferralLink.Rules do
  @moduledoc false
  # Loads rule_match rulesets straight from JSON files, so the host's
  # `:rule_match` adapter configuration (e.g. Ecto) is never consulted.

  @spec load(nil | Path.t() | RuleMatch.Ruleset.t(), Path.t()) ::
          {:ok, RuleMatch.Ruleset.t()} | {:error, {:ruleset, Path.t(), term()}}
  def load(nil, default), do: load(default, default)
  def load(%RuleMatch.Ruleset{} = ruleset, _default), do: {:ok, ruleset}

  def load(path, _default) when is_binary(path) do
    with {:ok, json} <- File.read(path),
         {:ok, ruleset} <- RuleMatch.Ruleset.from_json(json) do
      {:ok, ruleset}
    else
      {:error, reason} -> {:error, {:ruleset, path, reason}}
    end
  rescue
    # rule_match raises on valid JSON of the wrong shape (e.g. "rules": "x").
    e -> {:error, {:ruleset, path, Exception.message(e)}}
  end

  @spec priv(Path.t()) :: Path.t()
  def priv(relative), do: Application.app_dir(:appointment_referral_link, relative)
end
