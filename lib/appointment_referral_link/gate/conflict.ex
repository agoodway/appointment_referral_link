defmodule AppointmentReferralLink.Gate.Conflict do
  @moduledoc """
  Hard conflicts as a `rule_match` ruleset over the feature map. Every
  matching rule rejects the pair with its outcome `reason`. Reasons
  map to atoms through an allow-list (the shipped reasons plus
  `:conflict_reasons` from config); anything else becomes
  `:conflict_rule`, so no atoms are created from data.
  """

  alias AppointmentReferralLink.{Features, Rules}

  @known [:laterality_conflict, :specialty_mismatch]

  @spec default_path() :: Path.t()
  def default_path, do: Rules.priv("priv/rules/conflicts.json")

  @spec load(nil | Path.t() | RuleMatch.Ruleset.t()) ::
          {:ok, RuleMatch.Ruleset.t()} | {:error, term()}
  def load(source), do: Rules.load(source, default_path())

  @spec check(map(), RuleMatch.Ruleset.t(), [atom()]) :: {[atom()], [String.t()]}
  def check(features, ruleset, extra_reasons) do
    {:ok, matches} = RuleMatch.match(ruleset, Features.to_candidate(features))
    allowed = @known ++ extra_reasons
    reasons = matches |> Enum.map(&reason(&1.outcome, allowed)) |> Enum.uniq()
    {reasons, Enum.map(matches, & &1.rule.id)}
  end

  defp reason(%{reason: r}, allowed) when is_binary(r),
    do: Enum.find(allowed, :conflict_rule, &(Atom.to_string(&1) == r))

  defp reason(_outcome, _allowed), do: :conflict_rule
end
