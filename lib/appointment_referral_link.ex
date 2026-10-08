defmodule AppointmentReferralLink do
  @moduledoc """
  Links appointments to referrals. Each pair gets `:link`, `:reject`, or
  `:review`, with structured reasons and a score. Callers persist
  decisions; this package does not.

      {:ok, decisions} = AppointmentReferralLink.link(referral, appointments)

  See `AppointmentReferralLink.Config` for options.
  """

  alias AppointmentReferralLink.{Appointment, Config, Decision, Pipeline, Referral, Report}

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

  @doc """
  Runs labeled pairs (`%{referral:, appointment:, label: boolean}`)
  through the pipeline with one prepared config and reports precision,
  recall, review rate, and the cross-referral false-link rate. A false
  link is cross-referral when the same appointment is labeled true for a
  different referral in the set. Raises `ArgumentError` on invalid config.
  """
  @spec evaluate([map()], keyword()) :: Report.t()
  def evaluate(labeled, opts \\ []) when is_list(labeled) do
    config =
      with {:ok, config} <- Config.build(opts),
           {:ok, config} <- Pipeline.prepare(config) do
        config
      else
        {:error, reason} -> raise ArgumentError, "evaluate/2: #{inspect(reason)}"
      end

    truth =
      for %{label: true, referral: r, appointment: a} <- labeled, reduce: %{} do
        acc -> Map.update(acc, a.id, MapSet.new([r.id]), &MapSet.put(&1, r.id))
      end

    labeled
    |> Enum.map(fn %{referral: r, appointment: a, label: label} ->
      decision = Pipeline.run(r, a, config)
      owners = Map.get(truth, a.id, MapSet.new())
      cross? = decision.outcome == :link and not label and Enum.any?(owners, &(&1 != r.id))
      {decision.outcome, label, cross?}
    end)
    |> Report.build()
  end

  defp validate_appointments(appointments) do
    case Enum.find_index(appointments, &(not match?(%Appointment{}, &1))) do
      nil -> :ok
      index -> {:error, {:invalid_input, "element #{index} is not an %Appointment{}"}}
    end
  end
end
