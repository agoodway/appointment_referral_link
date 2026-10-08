defmodule AppointmentReferralLink do
  @moduledoc """
  Links appointments to referrals. Each pair gets `:link`, `:reject`, or
  `:review`, with structured reasons and a score. Callers persist
  decisions; this package does not.

      {:ok, decisions} = AppointmentReferralLink.link(referral, appointments)

  See `AppointmentReferralLink.Config` for options.
  """

  alias AppointmentReferralLink.{Appointment, Config, Decision, Pipeline, Referral}

  @doc """
  Decides every appointment against one referral. Returns one
  `%Decision{}` per appointment, in input order. Errors are reserved for
  invalid input, invalid config, or unreadable data files.
  """
  @spec link(Referral.t(), [Appointment.t()], keyword()) :: {:ok, [Decision.t()]} | {:error, term()}
  def link(referral, appointments, opts \\ [])

  def link(%Referral{} = referral, appointments, opts) when is_list(appointments) and is_list(opts) do
    with :ok <- validate_appointments(appointments),
         {:ok, config} <- Config.build(opts),
         {:ok, config} <- Pipeline.prepare(config) do
      {:ok, Enum.map(appointments, &Pipeline.run(referral, &1, config))}
    end
  end

  def link(_referral, _appointments, _opts),
    do: {:error, {:invalid_input, "expected a %Referral{} and a list of %Appointment{}"}}

  defp validate_appointments(appointments) do
    case Enum.find_index(appointments, &(not match?(%Appointment{}, &1))) do
      nil -> :ok
      index -> {:error, {:invalid_input, "element #{index} is not an %Appointment{}"}}
    end
  end
end
