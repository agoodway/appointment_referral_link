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

  @date_fields ~w(issued_on auth_start auth_end starts_on)
  @atom_fields ~w(laterality status)

  @doc "Loads golden cases. Test-only: uses String.to_existing_atom on fixture data."
  def load_cases(path) do
    # Reason and outcome atoms live in these modules; load them so
    # String.to_existing_atom/1 works when called at test compile time.
    Enum.each(
      [
        AppointmentReferralLink.Pipeline,
        AppointmentReferralLink.Threshold,
        AppointmentReferralLink.Gate.Window,
        AppointmentReferralLink.Gate.Conflict,
        AppointmentReferralLink.Laterality
      ],
      &Code.ensure_loaded!/1
    )

    %{"referrals" => refs, "base_appointment" => base, "cases" => cases} =
      path |> File.read!() |> JSON.decode!()

    referrals = Map.new(refs, fn {key, attrs} -> {key, to_struct(Referral, attrs)} end)

    Enum.map(cases, fn c ->
      %{
        name: c["name"],
        referral: Map.fetch!(referrals, c["referral"]),
        appointment: to_struct(Appointment, Map.merge(base, c["appointment"])),
        expected: String.to_existing_atom(c["expected"]),
        reasons: Enum.map(c["reasons"], &String.to_existing_atom/1),
        label: c["label"]
      }
    end)
  end

  defp to_struct(module, attrs) do
    struct!(module, Map.new(attrs, fn {k, v} -> {String.to_existing_atom(k), cast(k, v)} end))
  end

  defp cast(k, v) when k in @date_fields and is_binary(v), do: Date.from_iso8601!(v)
  defp cast(k, v) when k in @atom_fields and is_binary(v), do: String.to_existing_atom(v)
  defp cast(_k, v), do: v
end
