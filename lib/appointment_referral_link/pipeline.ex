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

  @doc """
  Decides every appointment against one referral, in input order. Pairs
  that need the text adapter are refined concurrently under a single
  `text_timeout` deadline for the whole batch.
  """
  @spec run_all(Referral.t(), [Appointment.t()], Config.t()) :: [Decision.t()]
  def run_all(%Referral{} = r, appointments, %Config{} = c) do
    staged = Enum.map(appointments, &stage(r, &1, c))
    refined = refine_all(for({:text, job} <- staged, do: job), c)

    Enum.map(staged, fn
      {:done, decision} -> decision
      {:text, job} -> finish(job, Map.fetch!(refined, job.id), c)
    end)
  end

  @spec run(Referral.t(), Appointment.t(), Config.t()) :: Decision.t()
  def run(%Referral{} = r, %Appointment{} = a, %Config{} = c), do: hd(run_all(r, [a], c))

  defp stage(r, a, c) do
    case gate(r, a, c) do
      %Decision{} = decision -> {:done, decision}
      {:text, job} -> {:text, job}
    end
  end

  defp gate(r, a, c) do
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
      {:text,
       %{
         id: make_ref(),
         referral: r,
         appointment: a,
         features: features,
         p: p,
         comps: comps,
         decision: d
       }}
    else
      decide(p, c, comps, d)
    end
  end

  defp finish(job, {:ok, refined}, c),
    do:
      decide(
        refined,
        c,
        Map.put(job.comps, :text, %{before: job.p, after: refined}),
        job.decision
      )

  defp finish(job, {:error, reason}, _c),
    do:
      review(
        job.decision,
        job.p,
        [:text_unavailable],
        Map.put(job.comps, :text, %{error: reason})
      )

  # Each adapter call runs in its own unlinked, monitored process: a crash
  # inside it (including one in a process it links to) becomes an error,
  # never an exit signal or leftover message in the caller. All calls share
  # one deadline, so a slow adapter costs about one `text_timeout` per
  # batch rather than one per pair.
  defp refine_all([], _c), do: %{}

  defp refine_all(jobs, c) do
    parent = self()

    workers =
      Map.new(jobs, fn job ->
        ref = make_ref()
        {pid, monitor} = spawn_monitor(fn -> send(parent, {ref, call_adapter(job, c)}) end)
        {ref, %{job_id: job.id, pid: pid, monitor: monitor}}
      end)

    monitors = Map.new(workers, fn {ref, w} -> {w.monitor, ref} end)
    collect(workers, monitors, System.monotonic_time(:millisecond) + c.text_timeout, %{})
  end

  defp call_adapter(job, c) do
    c.text_adapter.refine(job.referral, job.appointment, job.features, job.p, c)
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    kind, value -> {:error, {kind, value}}
  end

  defp collect(workers, _monitors, _deadline, acc) when map_size(workers) == 0, do: acc

  defp collect(workers, monitors, deadline, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {ref, result} when is_map_key(workers, ref) ->
        {w, workers} = Map.pop!(workers, ref)
        Process.demonitor(w.monitor, [:flush])

        collect(
          workers,
          Map.delete(monitors, w.monitor),
          deadline,
          Map.put(acc, w.job_id, text_result(result))
        )

      {:DOWN, monitor, :process, _pid, reason} when is_map_key(monitors, monitor) ->
        {ref, monitors} = Map.pop!(monitors, monitor)
        {w, workers} = Map.pop!(workers, ref)
        collect(workers, monitors, deadline, Map.put(acc, w.job_id, {:error, {:exit, reason}}))
    after
      remaining ->
        Enum.reduce(workers, acc, fn {ref, w}, acc ->
          Process.exit(w.pid, :kill)
          Process.demonitor(w.monitor, [:flush])

          receive do
            {^ref, _late} -> :ok
          after
            0 -> :ok
          end

          Map.put(acc, w.job_id, {:error, :timeout})
        end)
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

  # Config.build/1 has already checked that the scorer implements init/1.
  defp init_scorer(%Config{scorer: scorer} = c) do
    case scorer.init(c) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:scorer, {:bad_init, other}}}
    end
  rescue
    e -> {:error, {:scorer, {:exception, Exception.message(e)}}}
  catch
    kind, value -> {:error, {:scorer, {kind, value}}}
  end
end
