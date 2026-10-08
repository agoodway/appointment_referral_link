defmodule AppointmentReferralLink do
  @moduledoc """
  Links appointments to referrals. Each pair gets `:link`, `:reject`, or
  `:review`, with structured reasons and a score. Callers persist
  decisions; this package does not.

      {:ok, decisions} = AppointmentReferralLink.link(referral, appointments)

  See `AppointmentReferralLink.Config` for options.
  """

  alias AppointmentReferralLink.{
    Appointment,
    Config,
    Decision,
    Pipeline,
    Referral,
    Report,
    Validate
  }

  @doc """
  Decides every appointment against one referral. Returns one
  `%Decision{}` per appointment, in input order. Errors are reserved for
  invalid input, invalid config, or unreadable data files.
  """
  @spec link(Referral.t(), [Appointment.t()], keyword()) ::
          {:ok, [Decision.t()]} | {:error, term()}
  def link(referral, appointments, opts \\ [])

  def link(referral, appointments, opts) when is_list(opts) do
    with :ok <- Validate.input(referral, appointments),
         {:ok, config} <- Config.build(opts),
         {:ok, config} <- Pipeline.prepare(config) do
      {:ok, Pipeline.run_all(referral, appointments, config)}
    end
  end

  @doc """
  Runs labeled pairs (`%{referral:, appointment:, label: boolean}`)
  through the pipeline with one prepared config and reports precision,
  recall, review rate, and the cross-referral false-link rate. A false
  link is cross-referral when the same appointment is labeled true for a
  different referral in the set. Raises `ArgumentError` on invalid config
  or a malformed row (naming the row's index).
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

    validate_rows!(labeled)

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

  defp validate_rows!(labeled) do
    labeled
    |> Enum.with_index()
    |> Enum.each(fn
      {%{referral: r, appointment: a, label: label}, index} when is_boolean(label) ->
        case Validate.input(r, [a]) do
          :ok ->
            :ok

          {:error, {:invalid_input, msg}} ->
            raise ArgumentError, "evaluate/2: row #{index}: #{msg}"
        end

      {_row, index} ->
        raise ArgumentError,
              "evaluate/2: row #{index}: expected %{referral:, appointment:, label: boolean}"
    end)
  end
end
