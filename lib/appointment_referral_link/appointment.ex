defmodule AppointmentReferralLink.Appointment do
  @moduledoc """
  An appointment already known to belong to the referral's patient.
  Status is `:booked | :completed | :cancelled | :no_show`.
  `linked_referral_id` is set only when the appointment is linked to an
  open referral.
  """

  @type t :: %__MODULE__{
          id: term(),
          patient_id: term(),
          starts_on: Date.t() | nil,
          status: :booked | :completed | :cancelled | :no_show | nil,
          specialty: String.t() | nil,
          subspecialty: String.t() | nil,
          body_part: String.t() | nil,
          laterality: AppointmentReferralLink.Referral.laterality(),
          reason: String.t() | nil,
          cpt: [String.t()],
          icd10: [String.t()],
          rendering_provider_id: term(),
          site_id: term(),
          booked_from_referral: boolean() | nil,
          linked_referral_id: term(),
          patient: map() | nil
        }

  defstruct [
    :id,
    :patient_id,
    :starts_on,
    :status,
    :specialty,
    :subspecialty,
    :body_part,
    :laterality,
    :reason,
    :rendering_provider_id,
    :site_id,
    :booked_from_referral,
    :linked_referral_id,
    :patient,
    cpt: [],
    icd10: []
  ]
end
