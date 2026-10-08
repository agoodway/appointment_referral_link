defmodule AppointmentReferralLink.Config do
  @moduledoc """
  Runtime configuration. Defaults, then `config :appointment_referral_link`,
  then per-call options. `Pipeline.prepare/1` fills the runtime fields
  (`ontology`, `conflicts`, `cpt_table`, `scorer_state`, `fs_model`).
  """

  @defaults [
    lead_days: 7,
    lag_days: 14,
    default_auth_days: 90,
    drop_statuses: [:cancelled, :no_show],
    link_at: 0.92,
    reject_at: 0.35,
    review_low: nil,
    review_high: nil,
    patient_gate: :exact,
    fs_link_at: 0.95,
    scorer: AppointmentReferralLink.Score.Rules,
    text_adapter: AppointmentReferralLink.Score.Text.None,
    text_timeout: 2_000,
    ontology_paths: [],
    conflict_rules: nil,
    score_rules: nil,
    conflict_reasons: [],
    cpt_families: nil,
    tree_model_path: nil,
    tree_columns_path: nil
  ]

  @runtime [ontology: nil, conflicts: nil, cpt_table: nil, scorer_state: nil, fs_model: nil]

  @keys Keyword.keys(@defaults)

  defstruct @defaults ++ @runtime

  @type t :: %__MODULE__{}

  @doc "Merges defaults, application env, and `opts`, then validates."
  @spec build(keyword()) :: {:ok, t()} | {:error, {:invalid_config, String.t()}}
  def build(opts \\ []) when is_list(opts) do
    case Keyword.keys(opts) -- @keys do
      [] ->
        env = Keyword.take(Application.get_all_env(:appointment_referral_link), @keys)
        config = struct!(__MODULE__, @defaults |> Keyword.merge(env) |> Keyword.merge(opts))

        config = %{
          config
          | review_low: config.review_low || config.reject_at,
            review_high: config.review_high || config.link_at
        }

        validate(config)

      unknown ->
        error("unknown options: #{inspect(unknown)}")
    end
  end

  defp validate(c) do
    cond do
      not (prob?(c.link_at) and prob?(c.reject_at)) ->
        error("link_at and reject_at must be within [0, 1]")

      c.reject_at > c.link_at ->
        error("reject_at must not exceed link_at")

      not (prob?(c.review_low) and prob?(c.review_high) and c.review_low <= c.review_high) ->
        error("review_low..review_high must be an ordered range within [0, 1]")

      not Enum.all?([c.lead_days, c.lag_days, c.default_auth_days], &non_neg_int?/1) ->
        error("lead_days, lag_days and default_auth_days must be non-negative integers")

      not (is_integer(c.text_timeout) and c.text_timeout > 0) ->
        error("text_timeout must be a positive integer")

      not valid_gate?(c.patient_gate) ->
        error("patient_gate must be :exact or {:fellegi_sunter, model}")

      not prob?(c.fs_link_at) ->
        error("fs_link_at must be within [0, 1]")

      not (is_list(c.drop_statuses) and Enum.all?(c.drop_statuses, &is_atom/1)) ->
        error("drop_statuses must be a list of atoms")

      not (is_list(c.conflict_reasons) and Enum.all?(c.conflict_reasons, &is_atom/1)) ->
        error("conflict_reasons must be a list of atoms")

      not implements?(c.scorer, init: 1, score: 2) ->
        error("scorer must be a module implementing AppointmentReferralLink.Score")

      not implements?(c.text_adapter, refine: 5) ->
        error("text_adapter must be a module implementing AppointmentReferralLink.Score.Text")

      not (is_list(c.ontology_paths) and Enum.all?(c.ontology_paths, &is_binary/1)) ->
        error("ontology_paths must be a list of file paths")

      true ->
        {:ok, c}
    end
  end

  defp prob?(x), do: is_number(x) and x >= 0 and x <= 1
  defp non_neg_int?(x), do: is_integer(x) and x >= 0

  defp implements?(module, functions) when is_atom(module) and not is_nil(module) do
    Code.ensure_loaded?(module) and
      Enum.all?(functions, fn {name, arity} -> function_exported?(module, name, arity) end)
  end

  defp implements?(_module, _functions), do: false

  defp valid_gate?(:exact), do: true
  defp valid_gate?({:fellegi_sunter, model}) when not is_nil(model), do: true
  defp valid_gate?(_), do: false

  defp error(msg), do: {:error, {:invalid_config, msg}}
end
