defmodule AppointmentReferralLink.Gate.Patient do
  @moduledoc """
  Patient gate. `:exact` requires equal, non-nil `patient_id`.
  `{:fellegi_sunter, model}` requires `probability >= fs_link_at` with no
  `patient_matching` guard fired.
  """

  alias AppointmentReferralLink.{Appointment, Config, Identity.FellegiSunter, Referral}

  @spec check(Referral.t(), Appointment.t(), Config.t()) :: {:pass | :fail, map() | nil}
  def check(%Referral{patient_id: id}, %Appointment{patient_id: id}, %Config{patient_gate: :exact})
      when not is_nil(id),
      do: {:pass, nil}

  def check(_r, _a, %Config{patient_gate: :exact}), do: {:fail, nil}

  def check(r, a, %Config{patient_gate: {:fellegi_sunter, _}, fs_model: model, fs_link_at: at}) do
    case FellegiSunter.compare(r, a, model) do
      nil -> {:fail, nil}
      %{probability: p, guards: []} = identity when p >= at -> {:pass, identity}
      identity -> {:fail, identity}
    end
  end
end
