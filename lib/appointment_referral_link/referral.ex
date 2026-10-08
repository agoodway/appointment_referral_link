defmodule AppointmentReferralLink.Referral do
  @moduledoc """
  A referral as the source system describes it. Plain, serializable data:
  dates are `Date`, codes are strings, laterality is
  `:left | :right | :bilateral | nil`.

  `patient` is an optional demographics map in `patient_matching` record
  shape, read only by the Fellegi–Sunter patient gate.
  """

  @type laterality :: :left | :right | :bilateral | nil

  @type t :: %__MODULE__{
          id: term(),
          patient_id: term(),
          issued_on: Date.t() | nil,
          auth_start: Date.t() | nil,
          auth_end: Date.t() | nil,
          specialty: String.t() | nil,
          allowed_specialties: [String.t()],
          body_part: String.t() | nil,
          laterality: laterality(),
          reason: String.t() | nil,
          icd10: [String.t()],
          referring_provider_id: term(),
          site_id: term(),
          patient: map() | nil
        }

  defstruct [
    :id,
    :patient_id,
    :issued_on,
    :auth_start,
    :auth_end,
    :specialty,
    :body_part,
    :laterality,
    :reason,
    :referring_provider_id,
    :site_id,
    :patient,
    allowed_specialties: [],
    icd10: []
  ]
end
