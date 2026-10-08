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
end
