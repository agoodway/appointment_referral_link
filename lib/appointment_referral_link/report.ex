defmodule AppointmentReferralLink.Report do
  @moduledoc """
  Evaluation metrics over labeled pairs. A ratio is nil when its
  denominator is zero, except `cross_referral_false_link_rate`, which is
  0.0 when there are no links.
  """

  @type t :: %__MODULE__{
          precision: float() | nil,
          recall: float() | nil,
          review_rate: float() | nil,
          cross_referral_false_link_rate: float(),
          total: non_neg_integer(),
          counts: %{{atom(), boolean()} => non_neg_integer()}
        }

  defstruct [
    :precision,
    :recall,
    :review_rate,
    cross_referral_false_link_rate: 0.0,
    total: 0,
    counts: %{}
  ]

  @doc """
  Builds the report from `{outcome, label, cross_referral?}` tuples.
  `cross_referral?` is true for a `:link` labeled false whose appointment
  truly belongs to a different referral.
  """
  @spec build([{atom(), boolean(), boolean()}]) :: t()
  def build(results) do
    total = length(results)
    counts = Enum.frequencies_by(results, fn {outcome, label, _} -> {outcome, label} end)
    links = Enum.count(results, &match?({:link, _, _}, &1))
    positives = Enum.count(results, &match?({_, true, _}, &1))
    reviews = Enum.count(results, &match?({:review, _, _}, &1))
    cross = Enum.count(results, &match?({_, _, true}, &1))
    true_links = Map.get(counts, {:link, true}, 0)

    %__MODULE__{
      total: total,
      counts: counts,
      precision: ratio(true_links, links),
      recall: ratio(true_links, positives),
      review_rate: ratio(reviews, total),
      cross_referral_false_link_rate: ratio(cross, links) || 0.0
    }
  end

  defp ratio(_n, 0), do: nil
  defp ratio(n, d), do: n / d
end
