defmodule AppointmentReferralLink.Score.Rules do
  @moduledoc """
  Default scorer: a `rule_match` ruleset whose rule outcomes carry
  `weight`, plus `meta.intercept`. Every matching rule's weight is summed
  and passed through the logistic function. Swap the file with
  `:score_rules`.
  """

  @behaviour AppointmentReferralLink.Score

  alias AppointmentReferralLink.{Config, Features, Rules}

  @spec default_path() :: Path.t()
  def default_path, do: Rules.priv("priv/rules/score_weights.json")

  @impl true
  def init(%Config{score_rules: source}) do
    with {:ok, ruleset} <- Rules.load(source, default_path()) do
      case ruleset.meta do
        %{"intercept" => i} when is_number(i) -> {:ok, %{ruleset: ruleset, intercept: i}}
        _ -> {:error, {:score_rules, "meta.intercept must be a number"}}
      end
    end
  end

  @impl true
  def score(features, %{ruleset: ruleset, intercept: intercept}) do
    {:ok, matches} = RuleMatch.match(ruleset, Features.to_candidate(features))

    with {:ok, weights} <- weights(matches) do
      logit = intercept + Enum.sum(weights)
      {:ok, logistic(logit), %{logit: logit, rules: Enum.map(matches, & &1.rule.id)}}
    end
  end

  @spec logistic(number()) :: float()
  def logistic(x), do: 1.0 / (1.0 + :math.exp(-x))

  defp weights(matches) do
    Enum.reduce_while(matches, {:ok, []}, fn %{outcome: outcome, rule: rule}, {:ok, acc} ->
      case outcome do
        %{weight: w} when is_number(w) -> {:cont, {:ok, [w | acc]}}
        _ -> {:halt, {:error, {:bad_weight, rule.id}}}
      end
    end)
  end
end
