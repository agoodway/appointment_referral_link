defmodule AppointmentReferralLink.Pipeline do
  @moduledoc """
  Runs one pair through the stages. Gates can only reject; `Threshold`
  is reached only by pairs with no gate reason, so `:link` cannot follow
  a gate failure or a scorer or text failure.
  """

  alias AppointmentReferralLink.{
    Appointment,
    Config,
    CptFamilies,
    Decision,
    Features,
    Gate,
    Identity.FellegiSunter,
    Laterality,
    Ontology,
    Referral,
    Threshold
  }

  @doc "Loads data files, the scorer state, and the identity model once."
  @spec prepare(Config.t()) :: {:ok, Config.t()} | {:error, term()}
  def prepare(%Config{} = c) do
    with {:ok, ontology} <- Ontology.load([Ontology.default_path() | c.ontology_paths]),
         {:ok, conflicts} <- Gate.Conflict.load(c.conflict_rules),
         {:ok, cpt} <- CptFamilies.load(c.cpt_families || CptFamilies.default_path()),
         {:ok, fs_model} <- load_fs(c.patient_gate),
         {:ok, scorer_state} <- init_scorer(c) do
      {:ok,
       %{
         c
         | ontology: ontology,
           conflicts: conflicts,
           cpt_table: cpt,
           fs_model: fs_model,
           scorer_state: scorer_state
       }}
    end
  end

  @spec run(Referral.t(), Appointment.t(), Config.t()) :: Decision.t()
  def run(%Referral{} = r, %Appointment{} = a, %Config{} = c) do
    decision = %Decision{appointment_id: a.id, referral_id: r.id}

    case Gate.Patient.check(r, a, c) do
      {:fail, identity} -> reject(decision, [:patient_mismatch], %{identity: identity})
      {:pass, identity} -> window(r, a, c, %{identity: identity}, decision)
    end
  end

  defp window(r, a, c, comps, d) do
    case Gate.Window.check(r, a, c) do
      [] -> conflicts(fill(r), fill(a), c, comps, d)
      reasons -> reject(d, reasons, comps)
    end
  end

  defp fill(%{laterality: laterality, reason: text} = side),
    do: %{side | laterality: Laterality.fill(laterality, text)}

  defp conflicts(r, a, c, comps, d) do
    features = Features.build(r, a, c.ontology, c.cpt_table)
    comps = Map.put(comps, :features, features)

    case Gate.Conflict.check(features, c.conflicts, c.conflict_reasons) do
      {[], _} -> score(r, a, features, c, comps, d)
      {reasons, rule_ids} -> reject(d, reasons, Map.put(comps, :conflict_rules, rule_ids))
    end
  end

  defp score(r, a, features, c, comps, d) do
    comps = Map.put(comps, :scorer, c.scorer)

    case safe_score(c, features) do
      {:ok, p, details} -> text(r, a, features, p, c, Map.put(comps, :score, details), d)
      {:error, reason} -> review(d, nil, [:scorer_error], Map.put(comps, :score_error, reason))
    end
  end

  defp safe_score(c, features) do
    case c.scorer.score(features, c.scorer_state) do
      {:ok, p, details} when is_float(p) and p >= 0.0 and p <= 1.0 and is_map(details) ->
        {:ok, p, details}

      {:ok, p, _details} ->
        {:error, {:invalid_score, p}}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:bad_return, other}}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    kind, value -> {:error, {kind, value}}
  end

  defp text(r, a, features, p, c, comps, d) do
    if Threshold.in_band?(p, c) do
      case call_text(r, a, features, p, c) do
        {:ok, refined} ->
          decide(refined, c, Map.put(comps, :text, %{before: p, after: refined}), d)

        {:error, reason} ->
          review(d, p, [:text_unavailable], Map.put(comps, :text, %{error: reason}))
      end
    else
      decide(p, c, comps, d)
    end
  end

  # The adapter runs in an unlinked, monitored process: a crash inside it
  # (including one in a process it links to) becomes an error, never an
  # exit signal or leftover message in the caller.
  defp call_text(r, a, features, p, c) do
    parent = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          try do
            c.text_adapter.refine(r, a, features, p, c)
          rescue
            e -> {:error, {:exception, Exception.message(e)}}
          catch
            kind, value -> {:error, {kind, value}}
          end

        send(parent, {ref, result})
      end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        text_result(result)

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, {:exit, reason}}
    after
      c.text_timeout ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])

        receive do
          {^ref, _late} -> :ok
        after
          0 -> :ok
        end

        {:error, :timeout}
    end
  end

  defp text_result({:ok, refined}) when is_float(refined) and refined >= 0.0 and refined <= 1.0,
    do: {:ok, refined}

  defp text_result({:error, reason}), do: {:error, reason}
  defp text_result(other), do: {:error, {:bad_return, other}}

  defp decide(p, c, comps, d),
    do: %{d | outcome: Threshold.outcome(p, c), score: p, reasons: [:score], components: comps}

  defp reject(d, reasons, comps), do: %{d | outcome: :reject, reasons: reasons, components: comps}

  defp review(d, p, reasons, comps),
    do: %{d | outcome: :review, score: p, reasons: reasons, components: comps}

  defp load_fs(:exact), do: {:ok, nil}
  defp load_fs({:fellegi_sunter, model}), do: FellegiSunter.load(model)

  defp init_scorer(%Config{scorer: scorer} = c) do
    if Code.ensure_loaded?(scorer) and function_exported?(scorer, :init, 1) do
      scorer.init(c)
    else
      {:error, {:scorer, "#{inspect(scorer)} does not implement AppointmentReferralLink.Score"}}
    end
  end
end
