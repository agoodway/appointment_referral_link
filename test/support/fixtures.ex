defmodule AppointmentReferralLink.Fixtures do
  @moduledoc false

  alias AppointmentReferralLink.{Appointment, Referral}

  @doc "Referral R1: right knee, orthopedics, issued 2026-09-01."
  def referral(attrs \\ []) do
    struct!(
      %Referral{
        id: "ref_1",
        patient_id: "p_9",
        issued_on: ~D[2026-09-01],
        auth_start: ~D[2026-09-01],
        auth_end: ~D[2026-12-01],
        specialty: "orthopedics",
        allowed_specialties: ["orthopedics", "sports_medicine"],
        body_part: "knee",
        laterality: :right,
        reason: "locking and medial pain",
        icd10: ["M23.20"],
        referring_provider_id: "prv_3",
        site_id: "clinic_2"
      },
      attrs
    )
  end

  @doc "An appointment that cleanly links to `referral/0` under defaults."
  def appointment(attrs \\ []) do
    struct!(
      %Appointment{
        id: "appt_1",
        patient_id: "p_9",
        starts_on: ~D[2026-09-18],
        status: :completed,
        specialty: "orthopedics",
        subspecialty: "knee",
        body_part: "knee",
        laterality: :right,
        reason: "right knee locking",
        cpt: ["99203"],
        icd10: ["M23.21"],
        rendering_provider_id: "prv_8",
        site_id: "clinic_2",
        booked_from_referral: true,
        linked_referral_id: nil
      },
      attrs
    )
  end
end
