defmodule AppointmentReferralLink.Validate do
  @moduledoc false
  # Type checks on caller structs, so one malformed row returns
  # `{:error, {:invalid_input, _}}` instead of raising mid-pipeline or,
  # worse, slipping past a gate (e.g. status "cancelled" vs :cancelled).

  alias AppointmentReferralLink.{Appointment, Referral}

  @lateralities [:left, :right, :bilateral, nil]
  @statuses [:booked, :completed, :cancelled, :no_show, nil]

  @spec input(term(), term()) :: :ok | {:error, {:invalid_input, String.t()}}
  def input(%Referral{} = referral, appointments) when is_list(appointments) do
    with :ok <- referral(referral) do
      appointments
      |> Enum.with_index()
      |> Enum.reduce_while(:ok, fn {appointment, index}, :ok ->
        case appointment(appointment) do
          :ok -> {:cont, :ok}
          {:error, msg} -> {:halt, invalid("appointment #{index}: #{msg}")}
        end
      end)
    else
      {:error, msg} -> invalid("referral: #{msg}")
    end
  end

  def input(_referral, _appointments),
    do: invalid("expected a %Referral{} and a list of %Appointment{}")

  defp referral(r) do
    check([
      {:issued_on, date?(r.issued_on)},
      {:auth_start, date?(r.auth_start)},
      {:auth_end, date?(r.auth_end)},
      {:specialty, text?(r.specialty)},
      {:allowed_specialties, texts?(r.allowed_specialties)},
      {:body_part, text?(r.body_part)},
      {:laterality, r.laterality in @lateralities},
      {:reason, text?(r.reason)},
      {:icd10, texts?(r.icd10)},
      {:patient, map_or_nil?(r.patient)}
    ])
  end

  defp appointment(%Appointment{} = a) do
    check([
      {:starts_on, date?(a.starts_on)},
      {:status, a.status in @statuses},
      {:specialty, text?(a.specialty)},
      {:subspecialty, text?(a.subspecialty)},
      {:body_part, text?(a.body_part)},
      {:laterality, a.laterality in @lateralities},
      {:reason, text?(a.reason)},
      {:cpt, texts?(a.cpt)},
      {:icd10, texts?(a.icd10)},
      {:booked_from_referral,
       is_boolean(a.booked_from_referral) or is_nil(a.booked_from_referral)},
      {:patient, map_or_nil?(a.patient)}
    ])
  end

  defp appointment(_other), do: {:error, "not an %Appointment{}"}

  defp check(fields) do
    case Enum.find(fields, fn {_field, ok?} -> not ok? end) do
      nil -> :ok
      {field, false} -> {:error, "invalid #{field}"}
    end
  end

  defp date?(value), do: is_nil(value) or is_struct(value, Date)
  defp text?(value), do: is_nil(value) or is_binary(value)
  defp texts?(value), do: is_nil(value) or (is_list(value) and Enum.all?(value, &is_binary/1))
  defp map_or_nil?(value), do: is_nil(value) or (is_map(value) and not is_struct(value))

  defp invalid(msg), do: {:error, {:invalid_input, msg}}
end
