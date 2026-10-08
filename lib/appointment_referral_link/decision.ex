defmodule AppointmentReferralLink.Decision do
  @moduledoc """
  The outcome for one referral/appointment pair. `score` is nil when a
  gate rejected the pair. `reasons` are atoms; `components` hold the
  trace: `:identity`, `:features`, `:conflict_rules`, `:scorer`,
  `:score`, `:score_error`, `:text`.
  """

  @type outcome :: :link | :reject | :review

  @type t :: %__MODULE__{
          appointment_id: term(),
          referral_id: term(),
          outcome: outcome() | nil,
          score: float() | nil,
          reasons: [atom()],
          components: map()
        }

  defstruct [:appointment_id, :referral_id, :outcome, :score, reasons: [], components: %{}]
end
