defmodule AppointmentReferralLink.Gate.Window do
  @moduledoc """
  Blocking: the appointment must start within
  `[issued_on - lead_days, (auth_end || issued_on + default_auth_days) + lag_days]`
  (inclusive), must not have a dropped status, and must not be linked to
  a different referral. Returns every reason that applies.
  """

  alias AppointmentReferralLink.{Appointment, Config, Referral}

  @spec check(Referral.t(), Appointment.t(), Config.t()) :: [atom()]
  def check(%Referral{} = r, %Appointment{} = a, %Config{} = c) do
    []
    |> add(not in_window?(r, a, c), :outside_window)
    |> add(a.status in c.drop_statuses, :status_excluded)
    |> add(linked_elsewhere?(r, a), :already_linked)
    |> Enum.reverse()
  end

  @spec window(Referral.t(), Config.t()) :: {Date.t(), Date.t()} | nil
  def window(%Referral{issued_on: nil}, _c), do: nil

  def window(%Referral{issued_on: issued, auth_end: auth_end}, %Config{} = c) do
    finish = auth_end || Date.add(issued, c.default_auth_days)
    {Date.add(issued, -c.lead_days), Date.add(finish, c.lag_days)}
  end

  @spec linked_elsewhere?(Referral.t(), Appointment.t()) :: boolean()
  def linked_elsewhere?(%Referral{id: id}, %Appointment{linked_referral_id: linked}),
    do: not is_nil(linked) and linked != id

  defp in_window?(_r, %Appointment{starts_on: nil}, _c), do: false

  defp in_window?(r, %Appointment{starts_on: starts}, c) do
    case window(r, c) do
      nil -> false
      {from, to} -> Date.compare(starts, from) != :lt and Date.compare(starts, to) != :gt
    end
  end

  defp add(acc, true, reason), do: [reason | acc]
  defp add(acc, false, _reason), do: acc
end
