defmodule AppointmentReferralLink.Score.Text do
  @moduledoc """
  Text residual for pairs whose structured score sits in the review band.
  The pipeline calls `refine/5` under `text_timeout`; an error, exception,
  or timeout sends the pair to `:review`, never `:link`. The adapter can
  never overturn a gate: gated pairs never reach it.
  """

  alias AppointmentReferralLink.{Appointment, Config, Referral}

  @callback refine(Referral.t(), Appointment.t(), features :: map(), p :: float(), Config.t()) ::
              {:ok, float()} | {:error, term()}
end
