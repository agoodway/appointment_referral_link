# AppointmentReferralLink Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A deterministic appointment↔referral linker that returns
`:link | :reject | :review` per pair, with a structured trace. It uses
`rule_match` for rules and `patient_matching` for an optional
Fellegi–Sunter patient gate.

**Architecture:**
- A per-pair pipeline runs these stages in order: patient gate → window
  gate → laterality fill → features → conflict gate (`rule_match`) →
  scorer → optional text refinement → threshold.
- Gates can only reject. Only `Threshold` produces `:link`.
- Rules, weights, the ontology and CPT families are JSON data under `priv/`.

**Tech Stack:**
- Elixir 1.19 with the built-in `JSON` module
- `rule_match` and `patient_matching` as GitHub deps
- `ortex` as an optional dep
- `stream_data` for tests

**Spec:** `docs/superpowers/specs/2026-10-08-appointment-referral-link-design.md`

### Refinements to the spec made while planning (read these first)

1. **Scorer behaviour.** It is `init(Config.t()) :: {:ok, state} | {:error,
   reason}` plus `score(features, state) :: {:ok, float, details_map} |
   {:error, reason}`. Each scorer loads its own data in `init`, and the
   details map becomes `components.score`.
2. **Text behaviour.** It is `refine(referral, appointment, features, p,
   config)`.
3. **One fixture file.** Golden pairs and the labeled evaluation set are
   both `test/fixtures/golden.json`: each case carries both `expected` and
   `label`. This replaces the separate `labeled.json` named in the spec.
4. **`evaluate/2` runs pair by pair.** It runs each pair through the
   pipeline with one prepared config, which gives the same result as
   grouping by referral. It raises `ArgumentError` on invalid config.
5. **New config keys** (all nil by default, meaning use the shipped
   files): `cpt_families`, `tree_model_path`, `tree_columns_path`.

## Global Constraints

- OTP app `:appointment_referral_link`, root module `AppointmentReferralLink`.
  Do not rename them.
- Elixir `~> 1.19`. Use the built-in `JSON` module; do not add Jason.
- Deps, verbatim: `{:rule_match, github: "agoodway/rule_match"}`,
  `{:patient_matching, github: "agoodway/patient_matching"}`,
  `{:ortex, "~> 0.1.10", optional: true}`, `{:stream_data, "~> 1.1", only: :test}`.
- Never create atoms from data. Use `String.to_existing_atom` only on
  fixture or test data, and an allow-list lookup for rule outcomes.
- Reasons are atoms only. Detail goes in `components`.
- Missing values stay `nil`. Never impute 0 or false.
- `rule_match` compares atoms and strings as different values. Pass
  feature maps through `Features.to_candidate/1` before every
  `RuleMatch.match/3` call.
- Load rulesets with `File.read` + `RuleMatch.Ruleset.from_json/1`, never
  `RuleMatch.Ruleset.load/2`, which reads the host's `:rule_match` adapter
  config.
- Defaults: `lead_days: 7, lag_days: 14, default_auth_days: 90,
  drop_statuses: [:cancelled, :no_show], link_at: 0.92, reject_at: 0.35,
  fs_link_at: 0.95, text_timeout: 2_000`.
- No Laya and no Python runtime. The only Python file is a dev script that
  builds the test ONNX model.

## Review Focus

1. **Nil dates.** If `issued_on` or `starts_on` is nil, the pair is
   rejected with `:outside_window`, with no crash. Task 4 pins this.
2. **Bad elements in the appointments list.** A non-`%Appointment{}`
   element gives `{:error, {:invalid_input, _}}`, and an empty list gives
   `{:ok, []}`. Task 10 pins this.
3. **Bad scorer output.** A score outside [0, 1], an integer, or a raised
   exception gives `:review` with `:scorer_error`, never `:link`. Task 10
   pins this.
4. **Specialty case and whitespace.** `"Orthopedics "` vs `"orthopedics"`
   is `:exact`, not a conflict. Task 6 pins this.
5. **`linked_referral_id` equal to the referral's own id.** This is not
   `:already_linked`. Task 4 pins this.

## File Structure

```
mix.exs                                         deps, elixirc_paths
lib/appointment_referral_link.ex                link/3, evaluate/2
lib/appointment_referral_link/
  referral.ex appointment.ex decision.ex report.ex   structs
  config.ex                                     defaults, env merge, validation
  laterality.ex                                 token fill + compare
  ontology.ex                                   body-part JSON → match/3
  cpt_families.ex                               specialty→CPT ranges JSON → count/3
  rules.ex                                      shared ruleset file loader
  features.ex                                   pair → feature map; to_candidate/1
  gate/patient.ex gate/window.ex gate/conflict.ex
  identity/fellegi_sunter.ex
  score.ex score/rules.ex score/tree.ex score/tree/encoder.ex
  score/text.ex score/text/none.ex
  threshold.ex
  pipeline.ex                                   prepare/1, run/3
priv/ontology/body_parts.json
priv/codes/specialty_cpt.json
priv/rules/conflicts.json
priv/rules/score_weights.json
scripts/make_test_tree.py                       dev-only, builds the ONNX test fixture
test/support/fixtures.ex test/support/stubs.ex
test/fixtures/golden.json test/fixtures/baseline.json
test/fixtures/models/linker.onnx test/fixtures/models/linker.features.json
test/appointment_referral_link/*_test.exs
```

---

### Task 1: Dependencies, data structs, and Config

**Files:**
- Modify: `mix.exs`
- Modify: `test/test_helper.exs`
- Replace: `lib/appointment_referral_link.ex` (remove `hello/0`)
- Delete: `test/appointment_referral_link_test.exs` (Task 10 recreates it)
- Create: `lib/appointment_referral_link/{referral,appointment,decision,report,config}.ex`
- Create: `test/support/fixtures.ex`
- Test: `test/appointment_referral_link/config_test.exs`

**Interfaces:**
- Produces:
  - Structs `%Referral{}`, `%Appointment{}`, `%Decision{}`, `%Report{}`
    with the fields below.
  - `Config.build(keyword()) :: {:ok, %Config{}} | {:error, {:invalid_config, String.t()}}`
  - `Config` runtime fields `ontology, conflicts, cpt_table, scorer_state,
    fs_model`, which `Pipeline.prepare/1` fills in.
  - `Fixtures.referral(keyword)` and `Fixtures.appointment(keyword)`, which
    return the base pair. With defaults they form a clean link.

- [ ] **Step 1: Update mix.exs and test_helper**

```elixir
defmodule AppointmentReferralLink.MixProject do
  use Mix.Project

  def project do
    [
      app: :appointment_referral_link,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:rule_match, github: "agoodway/rule_match"},
      {:patient_matching, github: "agoodway/patient_matching"},
      {:stream_data, "~> 1.1", only: :test}
    ]
  end
end
```

`test/test_helper.exs`:

```elixir
ExUnit.start(exclude: [:ortex])
```

Run: `mix deps.get && mix compile`
Expected: deps fetch and compile with no errors.

- [ ] **Step 2: Replace the scaffold module and delete the scaffold test**

`lib/appointment_referral_link.ex`:

```elixir
defmodule AppointmentReferralLink do
  @moduledoc """
  Links appointments to referrals. Each pair gets `:link`, `:reject`, or
  `:review`, with structured reasons and a score.
  """
end
```

Run: `rm test/appointment_referral_link_test.exs`

- [ ] **Step 3: Create the structs**

`lib/appointment_referral_link/referral.ex`:

```elixir
defmodule AppointmentReferralLink.Referral do
  @moduledoc """
  A referral as the source system describes it. Plain, serializable data:
  dates are `Date`, codes are strings, laterality is
  `:left | :right | :bilateral | nil`.

  `patient` is an optional demographics map in `patient_matching` record
  shape, read only by the Fellegi–Sunter patient gate.
  """

  @type laterality :: :left | :right | :bilateral | nil

  @type t :: %__MODULE__{
          id: term(),
          patient_id: term(),
          issued_on: Date.t() | nil,
          auth_start: Date.t() | nil,
          auth_end: Date.t() | nil,
          specialty: String.t() | nil,
          allowed_specialties: [String.t()],
          body_part: String.t() | nil,
          laterality: laterality(),
          reason: String.t() | nil,
          icd10: [String.t()],
          referring_provider_id: term(),
          site_id: term(),
          patient: map() | nil
        }

  defstruct [
    :id,
    :patient_id,
    :issued_on,
    :auth_start,
    :auth_end,
    :specialty,
    :body_part,
    :laterality,
    :reason,
    :referring_provider_id,
    :site_id,
    :patient,
    allowed_specialties: [],
    icd10: []
  ]
end
```

`lib/appointment_referral_link/appointment.ex`:

```elixir
defmodule AppointmentReferralLink.Appointment do
  @moduledoc """
  An appointment already known to belong to the referral's patient.
  Status is `:booked | :completed | :cancelled | :no_show`.
  `linked_referral_id` is set only when the appointment is linked to an
  open referral.
  """

  @type t :: %__MODULE__{
          id: term(),
          patient_id: term(),
          starts_on: Date.t() | nil,
          status: :booked | :completed | :cancelled | :no_show | nil,
          specialty: String.t() | nil,
          subspecialty: String.t() | nil,
          body_part: String.t() | nil,
          laterality: AppointmentReferralLink.Referral.laterality(),
          reason: String.t() | nil,
          cpt: [String.t()],
          icd10: [String.t()],
          rendering_provider_id: term(),
          site_id: term(),
          booked_from_referral: boolean() | nil,
          linked_referral_id: term(),
          patient: map() | nil
        }

  defstruct [
    :id,
    :patient_id,
    :starts_on,
    :status,
    :specialty,
    :subspecialty,
    :body_part,
    :laterality,
    :reason,
    :rendering_provider_id,
    :site_id,
    :booked_from_referral,
    :linked_referral_id,
    :patient,
    cpt: [],
    icd10: []
  ]
end
```

`lib/appointment_referral_link/decision.ex`:

```elixir
defmodule AppointmentReferralLink.Decision do
  @moduledoc """
  The outcome for one referral/appointment pair. `score` is nil when a
  gate rejected the pair. `reasons` are atoms; `components` hold the
  trace: `:identity`, `:features`, `:conflict_rules`, `:scorer`,
  `:score`, `:score_error`, `:text`.
  """

  @type outcome :: :link | :reject | :review

  @type t :: %__MODULE__{
          appointment_id: term(),
          referral_id: term(),
          outcome: outcome() | nil,
          score: float() | nil,
          reasons: [atom()],
          components: map()
        }

  defstruct [:appointment_id, :referral_id, :outcome, :score, reasons: [], components: %{}]
end
```

`lib/appointment_referral_link/report.ex` (Task 12 adds `build/1`):

```elixir
defmodule AppointmentReferralLink.Report do
  @moduledoc """
  Evaluation metrics over labeled pairs. A ratio is nil when its
  denominator is zero, except `cross_referral_false_link_rate`, which is
  0.0 when there are no links.
  """

  @type t :: %__MODULE__{
          precision: float() | nil,
          recall: float() | nil,
          review_rate: float() | nil,
          cross_referral_false_link_rate: float(),
          total: non_neg_integer(),
          counts: %{{atom(), boolean()} => non_neg_integer()}
        }

  defstruct [
    :precision,
    :recall,
    :review_rate,
    cross_referral_false_link_rate: 0.0,
    total: 0,
    counts: %{}
  ]
end
```

- [ ] **Step 4: Write the failing Config tests**

`test/appointment_referral_link/config_test.exs`:

```elixir
defmodule AppointmentReferralLink.ConfigTest do
  use ExUnit.Case, async: false

  alias AppointmentReferralLink.Config

  test "defaults are conservative and the review band follows the thresholds" do
    assert {:ok, c} = Config.build([])
    assert c.lead_days == 7
    assert c.lag_days == 14
    assert c.default_auth_days == 90
    assert c.drop_statuses == [:cancelled, :no_show]
    assert c.link_at == 0.92
    assert c.reject_at == 0.35
    assert c.review_low == 0.35
    assert c.review_high == 0.92
    assert c.patient_gate == :exact
    assert c.scorer == AppointmentReferralLink.Score.Rules
    assert c.text_adapter == AppointmentReferralLink.Score.Text.None
  end

  test "per-call options override application env" do
    Application.put_env(:appointment_referral_link, :lead_days, 3)
    on_exit(fn -> Application.delete_env(:appointment_referral_link, :lead_days) end)

    assert {:ok, %{lead_days: 3}} = Config.build([])
    assert {:ok, %{lead_days: 5}} = Config.build(lead_days: 5)
  end

  test "rejects unknown options" do
    assert {:error, {:invalid_config, msg}} = Config.build(lead_dayz: 3)
    assert msg =~ "lead_dayz"
  end

  test "rejects reject_at above link_at" do
    assert {:error, {:invalid_config, _}} = Config.build(link_at: 0.5, reject_at: 0.6)
  end

  test "rejects probabilities outside [0, 1]" do
    assert {:error, {:invalid_config, _}} = Config.build(link_at: 1.5)
    assert {:error, {:invalid_config, _}} = Config.build(review_low: -0.1)
  end

  test "rejects an inverted review band" do
    assert {:error, {:invalid_config, _}} = Config.build(review_low: 0.8, review_high: 0.5)
  end

  test "rejects negative day windows" do
    assert {:error, {:invalid_config, _}} = Config.build(lag_days: -1)
  end

  test "rejects a Fellegi–Sunter gate without a model" do
    assert {:error, {:invalid_config, _}} = Config.build(patient_gate: {:fellegi_sunter, nil})
    assert {:error, {:invalid_config, _}} = Config.build(patient_gate: :fuzzy)
  end

  test "rejects non-atom conflict reasons" do
    assert {:error, {:invalid_config, _}} = Config.build(conflict_reasons: ["x"])
  end
end
```

- [ ] **Step 5: Run the tests to verify they fail**

Run: `mix test test/appointment_referral_link/config_test.exs`
Expected: FAIL. `AppointmentReferralLink.Config.build/1 is undefined`.

- [ ] **Step 6: Implement Config**

`lib/appointment_referral_link/config.ex`:

```elixir
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

      true ->
        {:ok, c}
    end
  end

  defp prob?(x), do: is_number(x) and x >= 0 and x <= 1
  defp non_neg_int?(x), do: is_integer(x) and x >= 0

  defp valid_gate?(:exact), do: true
  defp valid_gate?({:fellegi_sunter, model}) when not is_nil(model), do: true
  defp valid_gate?(_), do: false

  defp error(msg), do: {:error, {:invalid_config, msg}}
end
```

- [ ] **Step 7: Create the test fixtures helper**

`test/support/fixtures.ex` (Task 14 adds `load_cases/1`):

```elixir
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
end
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `mix test`
Expected: all Config tests PASS.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "feat: add deps, data structs, and validated config"
```

---

### Task 2: Laterality

**Files:**
- Create: `lib/appointment_referral_link/laterality.ex`
- Test: `test/appointment_referral_link/laterality_test.exs`

**Interfaces:**
- Produces:
  - `Laterality.from_text(String.t() | nil) :: :left | :right | :bilateral | nil`
  - `Laterality.fill(current, text)`: returns `current` unless it is nil
  - `Laterality.compare(a, b) :: :agree | :conflict | :unknown`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule AppointmentReferralLink.LateralityTest do
  use ExUnit.Case, async: true

  alias AppointmentReferralLink.Laterality

  describe "from_text/1" do
    test "reads right and left tokens" do
      assert Laterality.from_text("Right knee locking") == :right
      assert Laterality.from_text("rt knee pain") == :right
      assert Laterality.from_text("LT knee") == :left
      assert Laterality.from_text("left-knee pain") == :left
    end

    test "reads bilateral tokens and both sides as bilateral" do
      assert Laterality.from_text("bilateral knee pain") == :bilateral
      assert Laterality.from_text("bilat knees") == :bilateral
      assert Laterality.from_text("both knees") == :bilateral
      assert Laterality.from_text("right and left knee") == :bilateral
    end

    test "does not match inside other words" do
      assert Laterality.from_text("brightness and lethargy") == nil
      assert Laterality.from_text("multiple lesions") == nil
    end

    test "nil and no tokens give nil" do
      assert Laterality.from_text(nil) == nil
      assert Laterality.from_text("knee locking") == nil
    end
  end

  test "fill/2 only fills nil" do
    assert Laterality.fill(nil, "lt knee") == :left
    assert Laterality.fill(:right, "lt knee") == :right
    assert Laterality.fill(nil, nil) == nil
  end

  test "compare/2" do
    assert Laterality.compare(:right, :right) == :agree
    assert Laterality.compare(:right, :bilateral) == :agree
    assert Laterality.compare(:bilateral, :left) == :agree
    assert Laterality.compare(:right, :left) == :conflict
    assert Laterality.compare(nil, :left) == :unknown
    assert Laterality.compare(:right, nil) == :unknown
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/appointment_referral_link/laterality_test.exs`
Expected: FAIL. `Laterality.from_text/1 is undefined`.

- [ ] **Step 3: Implement**

```elixir
defmodule AppointmentReferralLink.Laterality do
  @moduledoc """
  Laterality tokens from free text, used only to fill a missing
  structured field. No other narrative parsing.
  """

  @right ~w(rt right)
  @left ~w(lt left)
  @bilateral ~w(bilateral bilat both)

  @type t :: :left | :right | :bilateral | nil

  @spec from_text(String.t() | nil) :: t()
  def from_text(nil), do: nil

  def from_text(text) when is_binary(text) do
    tokens = text |> String.downcase() |> String.split(~r/[^a-z]+/, trim: true) |> MapSet.new()
    has? = fn words -> Enum.any?(words, &MapSet.member?(tokens, &1)) end
    right? = has?.(@right)
    left? = has?.(@left)

    cond do
      has?.(@bilateral) or (right? and left?) -> :bilateral
      right? -> :right
      left? -> :left
      true -> nil
    end
  end

  @spec fill(t(), String.t() | nil) :: t()
  def fill(nil, text), do: from_text(text)
  def fill(laterality, _text), do: laterality

  @spec compare(t(), t()) :: :agree | :conflict | :unknown
  def compare(nil, _), do: :unknown
  def compare(_, nil), do: :unknown
  def compare(same, same), do: :agree
  def compare(:bilateral, _), do: :agree
  def compare(_, :bilateral), do: :agree
  def compare(_, _), do: :conflict
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/appointment_referral_link/laterality_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/appointment_referral_link/laterality.ex test/appointment_referral_link/laterality_test.exs
git commit -m "feat: laterality token fill and comparison"
```

---

### Task 3: Body-part ontology

**Files:**
- Create: `priv/ontology/body_parts.json`
- Create: `lib/appointment_referral_link/ontology.ex`
- Test: `test/appointment_referral_link/ontology_test.exs`

**Interfaces:**
- Produces:
  - `Ontology.default_path() :: Path.t()`
  - `Ontology.load([Path.t()]) :: {:ok, %Ontology{}} | {:error, {:ontology, path, reason}}`
  - `Ontology.match(%Ontology{}, a, b) :: :exact | :related | :mismatch | :unknown`
  - `Ontology.normalize(String.t()) :: String.t()`

- [ ] **Step 1: Create the ontology data**

`priv/ontology/body_parts.json`:

```json
{
  "format": 1,
  "parts": {
    "knee": {
      "synonyms": ["knee joint", "knees"],
      "children": ["medial knee", "lateral knee", "patella", "kneecap", "acl", "pcl", "mcl", "lcl", "meniscus", "medial meniscus", "lateral meniscus"]
    },
    "shoulder": {
      "synonyms": ["shoulder joint", "shoulders"],
      "children": ["rotator cuff", "ac joint", "acromioclavicular joint", "glenohumeral joint", "labrum"]
    },
    "hip": {
      "synonyms": ["hip joint", "hips"],
      "children": ["groin", "acetabulum", "greater trochanter", "hip labrum"]
    },
    "ankle": {
      "synonyms": ["ankle joint", "ankles"],
      "children": ["achilles", "achilles tendon", "lateral ankle", "medial ankle"]
    },
    "foot": {
      "synonyms": ["feet"],
      "children": ["heel", "plantar fascia", "toe", "great toe", "forefoot", "midfoot", "hindfoot"]
    },
    "wrist": {
      "synonyms": ["wrists"],
      "children": ["carpal tunnel", "scaphoid", "tfcc"]
    },
    "hand": {
      "synonyms": ["hands"],
      "children": ["finger", "thumb", "palm", "metacarpal"]
    },
    "elbow": {
      "synonyms": ["elbows"],
      "children": ["lateral epicondyle", "medial epicondyle", "olecranon"]
    },
    "spine": {
      "synonyms": ["back"],
      "children": ["lumbar spine", "low back", "lower back", "cervical spine", "neck", "thoracic spine", "sacrum"]
    }
  }
}
```

- [ ] **Step 2: Write the failing test**

```elixir
defmodule AppointmentReferralLink.OntologyTest do
  use ExUnit.Case, async: true

  alias AppointmentReferralLink.Ontology

  setup do
    {:ok, ontology} = Ontology.load([Ontology.default_path()])
    %{ontology: ontology}
  end

  test "same canonical part or synonym is exact", %{ontology: o} do
    assert Ontology.match(o, "knee", "knee") == :exact
    assert Ontology.match(o, " Knee ", "knee joint") == :exact
    assert Ontology.match(o, "medial  knee", "Medial Knee") == :exact
  end

  test "a child of the same part is related", %{ontology: o} do
    assert Ontology.match(o, "knee", "medial knee") == :related
    assert Ontology.match(o, "patella", "knee") == :related
    assert Ontology.match(o, "patella", "meniscus") == :related
  end

  test "different parts mismatch", %{ontology: o} do
    assert Ontology.match(o, "knee", "shoulder") == :mismatch
    assert Ontology.match(o, "medial knee", "rotator cuff") == :mismatch
  end

  test "nil or unknown terms are unknown, never mismatch", %{ontology: o} do
    assert Ontology.match(o, nil, "knee") == :unknown
    assert Ontology.match(o, "knee", nil) == :unknown
    assert Ontology.match(o, "knee", "zygomatic arch") == :unknown
  end

  @tag :tmp_dir
  test "a site file extends the shipped ontology", %{tmp_dir: dir} do
    path = Path.join(dir, "site.json")

    File.write!(path, ~s({"format": 1, "parts": {"knee": {"children": ["popliteal fossa"]},
      "jaw": {"synonyms": ["tmj"]}}}))

    {:ok, o} = Ontology.load([Ontology.default_path(), path])
    assert Ontology.match(o, "knee", "popliteal fossa") == :related
    assert Ontology.match(o, "knee", "medial knee") == :related
    assert Ontology.match(o, "jaw", "tmj") == :exact
  end

  @tag :tmp_dir
  test "a missing or malformed file is an error", %{tmp_dir: dir} do
    bad = Path.join(dir, "bad.json")
    File.write!(bad, ~s({"format": 2}))

    assert {:error, {:ontology, _, _}} = Ontology.load([Path.join(dir, "nope.json")])
    assert {:error, {:ontology, ^bad, :invalid_format}} = Ontology.load([bad])
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `mix test test/appointment_referral_link/ontology_test.exs`
Expected: FAIL. `Ontology.load/1 is undefined`.

- [ ] **Step 4: Implement**

```elixir
defmodule AppointmentReferralLink.Ontology do
  @moduledoc """
  Body-part vocabulary shipped as data. Each canonical part has synonyms
  (the same part) and children (a narrower region of it). Sites extend it
  with extra files through the `:ontology_paths` option; files merge by
  union.

  File format: `{"format": 1, "parts": {"knee": {"synonyms": [...], "children": [...]}}}`.
  """

  defstruct index: %{}

  @type t :: %__MODULE__{index: %{String.t() => {String.t(), :self | :child}}}
  @type match :: :exact | :related | :mismatch | :unknown

  @spec default_path() :: Path.t()
  def default_path,
    do: Application.app_dir(:appointment_referral_link, "priv/ontology/body_parts.json")

  @spec load([Path.t()]) :: {:ok, t()} | {:error, {:ontology, Path.t(), term()}}
  def load(paths) when is_list(paths) do
    paths
    |> Enum.reduce_while({:ok, %{}}, fn path, {:ok, acc} ->
      case read(path) do
        {:ok, parts} -> {:cont, {:ok, merge(acc, parts)}}
        {:error, reason} -> {:halt, {:error, {:ontology, path, reason}}}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, %__MODULE__{index: index(parts)}}
      error -> error
    end
  end

  @doc "Compares two terms. Nil or unknown terms give `:unknown`."
  @spec match(t(), String.t() | nil, String.t() | nil) :: match()
  def match(_ontology, nil, _), do: :unknown
  def match(_ontology, _, nil), do: :unknown

  def match(%__MODULE__{index: index}, a, b) do
    na = normalize(a)
    nb = normalize(b)

    case {Map.get(index, na), Map.get(index, nb)} do
      {nil, _} -> :unknown
      {_, nil} -> :unknown
      {{c, _}, {c, _}} when na == nb -> :exact
      {{c, :self}, {c, :self}} -> :exact
      {{c, _}, {c, _}} -> :related
      _ -> :mismatch
    end
  end

  @spec normalize(String.t()) :: String.t()
  def normalize(term),
    do: term |> String.trim() |> String.downcase() |> String.replace(~r/\s+/, " ")

  defp read(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"format" => 1, "parts" => parts}} when is_map(parts) <- JSON.decode(body),
         true <- Enum.all?(parts, fn {_, spec} -> is_map(spec) end) do
      {:ok,
       Map.new(parts, fn {name, spec} ->
         {normalize(name), %{synonyms: terms(spec, "synonyms"), children: terms(spec, "children")}}
       end)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_format}
    end
  end

  defp terms(spec, key), do: spec |> Map.get(key, []) |> Enum.map(&normalize/1) |> MapSet.new()

  defp merge(acc, parts) do
    Map.merge(acc, parts, fn _name, a, b ->
      %{synonyms: MapSet.union(a.synonyms, b.synonyms), children: MapSet.union(a.children, b.children)}
    end)
  end

  # Canonical names and synonyms win over a child entry with the same text.
  defp index(parts) do
    children =
      for {canon, spec} <- parts, child <- spec.children, into: %{}, do: {child, {canon, :child}}

    selves =
      for {canon, spec} <- parts,
          term <- [canon | MapSet.to_list(spec.synonyms)],
          into: %{},
          do: {term, {canon, :self}}

    Map.merge(children, selves)
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `mix test test/appointment_referral_link/ontology_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add priv/ontology lib/appointment_referral_link/ontology.ex test/appointment_referral_link/ontology_test.exs
git commit -m "feat: body-part ontology loaded from extensible JSON"
```

---

### Task 4: Window gate

**Files:**
- Create: `lib/appointment_referral_link/gate/window.ex`
- Test: `test/appointment_referral_link/gate/window_test.exs`

**Interfaces:**
- Consumes: `Config.build/1`, `Fixtures.referral/1`, `Fixtures.appointment/1`
- Produces:
  - `Gate.Window.check(Referral.t(), Appointment.t(), Config.t()) :: [atom()]`:
    the empty list means pass. The reasons are, in order,
    `:outside_window`, `:status_excluded`, `:already_linked`.
  - `Gate.Window.window(Referral.t(), Config.t()) :: {Date.t(), Date.t()} | nil`
  - `Gate.Window.linked_elsewhere?(Referral.t(), Appointment.t()) :: boolean()`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule AppointmentReferralLink.Gate.WindowTest do
  use ExUnit.Case, async: true

  import AppointmentReferralLink.Fixtures
  alias AppointmentReferralLink.{Config, Gate.Window}

  setup do
    {:ok, config} = Config.build([])
    %{c: config}
  end

  test "window is issued_on - lead_days to auth_end + lag_days", %{c: c} do
    assert Window.window(referral(), c) == {~D[2026-08-25], ~D[2026-12-15]}
  end

  test "without auth_end the window ends default_auth_days after issue", %{c: c} do
    assert Window.window(referral(auth_end: nil), c) == {~D[2026-08-25], ~D[2026-12-14]}
  end

  test "both edges are inclusive", %{c: c} do
    assert Window.check(referral(), appointment(starts_on: ~D[2026-08-25]), c) == []
    assert Window.check(referral(), appointment(starts_on: ~D[2026-12-15]), c) == []
    assert Window.check(referral(), appointment(starts_on: ~D[2026-08-24]), c) == [:outside_window]
    assert Window.check(referral(), appointment(starts_on: ~D[2026-12-16]), c) == [:outside_window]
  end

  test "nil dates fall outside the window instead of crashing", %{c: c} do
    assert Window.check(referral(issued_on: nil), appointment(), c) == [:outside_window]
    assert Window.check(referral(), appointment(starts_on: nil), c) == [:outside_window]
  end

  test "dropped statuses are excluded", %{c: c} do
    assert Window.check(referral(), appointment(status: :cancelled), c) == [:status_excluded]
    assert Window.check(referral(), appointment(status: :no_show), c) == [:status_excluded]
    assert Window.check(referral(), appointment(status: :booked), c) == []
  end

  test "drop_statuses is configurable" do
    {:ok, c} = Config.build(drop_statuses: [])
    assert Window.check(referral(), appointment(status: :cancelled), c) == []
  end

  test "linked to a different referral is already_linked", %{c: c} do
    assert Window.check(referral(), appointment(linked_referral_id: "ref_2"), c) == [:already_linked]
  end

  test "linked to this same referral is not already_linked", %{c: c} do
    assert Window.check(referral(), appointment(linked_referral_id: "ref_1"), c) == []
  end

  test "collects every failing reason", %{c: c} do
    appt = appointment(starts_on: ~D[2027-06-01], status: :no_show, linked_referral_id: "ref_9")
    assert Window.check(referral(), appt, c) == [:outside_window, :status_excluded, :already_linked]
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/appointment_referral_link/gate/window_test.exs`
Expected: FAIL. `Window.window/2 is undefined`.

- [ ] **Step 3: Implement**

```elixir
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/appointment_referral_link/gate/window_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/appointment_referral_link/gate/window.ex test/appointment_referral_link/gate/window_test.exs
git commit -m "feat: window gate for date, status, and already-linked blocking"
```

---

### Task 5: Patient gate and Fellegi–Sunter identity

**Files:**
- Create: `lib/appointment_referral_link/identity/fellegi_sunter.ex`
- Create: `lib/appointment_referral_link/gate/patient.ex`
- Test: `test/appointment_referral_link/gate/patient_test.exs`

**Interfaces:**
- Consumes: `Config` (`patient_gate`, `fs_link_at`, `fs_model`)
- Produces:
  - `Identity.FellegiSunter.load(model | {json, pm_config}) :: {:ok, model} | {:error, {:fs_model, String.t()}}`
  - `Identity.FellegiSunter.compare(Referral.t(), Appointment.t(), model) :: %{probability: float, guards: [atom]} | nil`
  - `Gate.Patient.check(Referral.t(), Appointment.t(), Config.t()) :: {:pass | :fail, identity :: map() | nil}`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule AppointmentReferralLink.Gate.PatientTest do
  use ExUnit.Case, async: true

  import AppointmentReferralLink.Fixtures
  alias AppointmentReferralLink.{Config, Gate.Patient, Identity.FellegiSunter}

  # Synthetic records from the patient_matching README.
  @alice %{given_name: "Alice", family_name: "Example", dob: "1980-01-10", sex: "F",
           zip: "02139", phone: "2125550101", ssn: "212456789"}
  @carol %{given_name: "Carol", family_name: "Fiction", dob: "1980-09-15", sex: "F",
           zip: "60601", phone: "3125550103", ssn: "345678901"}

  setup_all do
    records = [
      Map.put(@alice, :id, "a1"),
      %{id: "a2", given_name: "Brian", family_name: "Sample", dob: "1980-06-12", sex: "M",
        zip: "10001", phone: "2125550102", ssn: "234567890"},
      Map.put(@carol, :id, "a3"),
      %{id: "b1", given_name: "Alicx", family_name: "Example", dob: "1980-01-10", sex: "F",
        zip: "02139", phone: "5550101", ssn: "212456789"},
      %{id: "b2", given_name: "Brian", family_name: "Sample", dob: "1980-06-13", sex: "M",
        zip: nil, phone: "2125550102", ssn: "234567890"}
    ]

    model = PatientMatching.train(records, PatientMatching.Presets.patient_mpi())
    %{model: model}
  end

  describe "exact gate" do
    setup do
      {:ok, c} = Config.build([])
      %{c: c}
    end

    test "passes on equal patient_id", %{c: c} do
      assert {:pass, nil} = Patient.check(referral(), appointment(), c)
    end

    test "fails on a different or nil patient_id", %{c: c} do
      assert {:fail, nil} = Patient.check(referral(), appointment(patient_id: "p_10"), c)
      assert {:fail, nil} = Patient.check(referral(patient_id: nil), appointment(patient_id: nil), c)
    end
  end

  describe "Fellegi–Sunter gate" do
    setup %{model: model} do
      {:ok, c} = Config.build(patient_gate: {:fellegi_sunter, model})
      {:ok, loaded} = FellegiSunter.load(model)
      %{c: %{c | fs_model: loaded}}
    end

    test "the same person passes, ignoring patient_id", %{c: c} do
      r = referral(patient_id: "src_a_1", patient: @alice)
      a = appointment(patient_id: "src_b_77", patient: @alice)
      assert {:pass, %{probability: p, guards: []}} = Patient.check(r, a, c)
      assert p >= 0.95
    end

    test "a different person fails", %{c: c} do
      r = referral(patient: @alice)
      a = appointment(patient: @carol)
      assert {:fail, %{probability: p}} = Patient.check(r, a, c)
      assert p < 0.95
    end

    test "missing demographics fail", %{c: c} do
      assert {:fail, nil} = Patient.check(referral(patient: nil), appointment(patient: @alice), c)
    end
  end

  test "load/1 accepts a dumped model with its config", %{model: model} do
    config = PatientMatching.Presets.patient_mpi()
    assert {:ok, _} = FellegiSunter.load({PatientMatching.dump(model), config})
    assert {:error, {:fs_model, _}} = FellegiSunter.load({"{}", config})
    assert {:error, {:fs_model, _}} = FellegiSunter.load(:nope)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/appointment_referral_link/gate/patient_test.exs`
Expected: FAIL. `Gate.Patient.check/3 is undefined`.

- [ ] **Step 3: Implement FellegiSunter**

```elixir
defmodule AppointmentReferralLink.Identity.FellegiSunter do
  @moduledoc """
  Optional identity comparator for source systems that share no patient
  identifier. Wraps `patient_matching`: the caller trains the model, and
  this module only loads it and scores one pair. The score is used for
  the gate and nothing downstream.
  """

  @spec load(struct() | {String.t(), struct()} | term()) ::
          {:ok, struct()} | {:error, {:fs_model, String.t()}}
  def load(%PatientMatching.Model{} = model), do: {:ok, model}

  def load({json, config}) when is_binary(json) do
    {:ok, PatientMatching.load(json, config)}
  rescue
    e -> {:error, {:fs_model, Exception.message(e)}}
  end

  def load(other), do: {:error, {:fs_model, "unsupported model: #{inspect(other, limit: 3)}"}}

  @doc "Scores the two `patient` maps. Nil when either side has none."
  @spec compare(map(), map(), struct()) :: %{probability: float(), guards: [atom()]} | nil
  def compare(%{id: rid, patient: rp}, %{id: aid, patient: ap}, model)
      when is_map(rp) and is_map(ap) do
    result =
      PatientMatching.explain(
        Map.put(rp, :id, {:referral, rid}),
        Map.put(ap, :id, {:appointment, aid}),
        model
      )

    %{probability: result.probability, guards: result.guards}
  end

  def compare(_referral, _appointment, _model), do: nil
end
```

- [ ] **Step 4: Implement Gate.Patient**

```elixir
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
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `mix test test/appointment_referral_link/gate/patient_test.exs`
Expected: PASS. If training raises because the set is too small, add
two more synthetic records with distinct names and DOBs to `records`.
Do not loosen the assertions.

- [ ] **Step 6: Commit**

```bash
git add lib/appointment_referral_link/identity lib/appointment_referral_link/gate/patient.ex test/appointment_referral_link/gate/patient_test.exs
git commit -m "feat: patient gate with exact id and optional Fellegi–Sunter"
```

---

### Task 6: CPT families and features

**Files:**
- Create: `priv/codes/specialty_cpt.json`
- Create: `lib/appointment_referral_link/cpt_families.ex`
- Create: `lib/appointment_referral_link/features.ex`
- Test: `test/appointment_referral_link/features_test.exs`

**Interfaces:**
- Consumes: `Ontology.load/1`, `Ontology.match/3`, `Laterality.compare/2`, `Gate.Window.linked_elsewhere?/2`
- Produces:
  - `CptFamilies.default_path()`
  - `CptFamilies.load(Path.t()) :: {:ok, %CptFamilies{}} | {:error, {:cpt_families, path, reason}}`
  - `CptFamilies.count(t, specialty, codes) :: non_neg_integer | nil`
  - `Features.build(Referral.t(), Appointment.t(), Ontology.t(), CptFamilies.t()) :: map()`,
    a map with exactly the keys in `Features.names/0`
  - `Features.names() :: [atom()]`
  - `Features.to_candidate(map()) :: map()`: atoms other than
    booleans and nil become strings

- [ ] **Step 1: Create the CPT data**

`priv/codes/specialty_cpt.json`:

```json
{
  "format": 1,
  "families": {
    "orthopedics": [["20000", "29999"], ["99202", "99215"]],
    "sports_medicine": [["20000", "29999"], ["97010", "97799"], ["99202", "99215"]],
    "physical_therapy": [["97010", "97799"]],
    "cardiology": [["92920", "93799"], ["99202", "99215"]],
    "neurology": [["95700", "96020"], ["99202", "99215"]]
  }
}
```

- [ ] **Step 2: Write the failing test**

```elixir
defmodule AppointmentReferralLink.FeaturesTest do
  use ExUnit.Case, async: true

  import AppointmentReferralLink.Fixtures
  alias AppointmentReferralLink.{CptFamilies, Features, Ontology}

  setup do
    {:ok, o} = Ontology.load([Ontology.default_path()])
    {:ok, cpt} = CptFamilies.load(CptFamilies.default_path())
    %{o: o, cpt: cpt}
  end

  test "base pair features", %{o: o, cpt: cpt} do
    f = Features.build(referral(), appointment(), o, cpt)

    assert Map.keys(f) |> Enum.sort() == Enum.sort(Features.names())
    assert f.days_from_issue == 17
    assert f.days_from_auth_start == 17
    assert f.days_to_auth_end == 74
    assert f.specialty_match == :exact
    assert f.subspecialty_match == :exact
    assert f.body_part_match == :exact
    assert f.laterality_match == :agree
    assert f.icd_overlap == 1
    assert f.cpt_in_referral_family == 1
    assert f.same_referring_provider == false
    assert f.booked_from_referral == true
    assert f.appointment_status == :completed
    assert f.site_match == true
    assert f.already_linked == false
    refute f.laterality_missing or f.body_part_missing or f.specialty_missing or f.icd_missing
  end

  test "specialty compares case- and whitespace-insensitively", %{o: o, cpt: cpt} do
    f = Features.build(referral(), appointment(specialty: " Orthopedics "), o, cpt)
    assert f.specialty_match == :exact
    f = Features.build(referral(), appointment(specialty: "Sports_Medicine"), o, cpt)
    assert f.specialty_match == :allowed
    f = Features.build(referral(), appointment(specialty: "cardiology"), o, cpt)
    assert f.specialty_match == :mismatch
  end

  test "missing values stay nil and set missingness flags", %{o: o, cpt: cpt} do
    r = referral(specialty: nil, auth_end: nil, auth_start: nil, laterality: nil, icd10: [])
    a = appointment(body_part: nil, site_id: nil, cpt: [], booked_from_referral: nil)
    f = Features.build(r, a, o, cpt)

    assert f.specialty_match == nil
    assert f.days_to_auth_end == nil
    assert f.days_from_auth_start == nil
    assert f.laterality_match == :unknown
    assert f.body_part_match == :unknown
    assert f.icd_overlap == nil
    assert f.cpt_in_referral_family == nil
    assert f.site_match == nil
    assert f.booked_from_referral == nil
    assert f.laterality_missing and f.body_part_missing and f.specialty_missing and f.icd_missing
  end

  test "icd_overlap counts shared 3-character categories", %{o: o, cpt: cpt} do
    r = referral(icd10: ["M23.20", "M25.561", "m23.9"])
    a = appointment(icd10: ["M23.21", "M25.50", "S83.2"])
    assert Features.build(r, a, o, cpt).icd_overlap == 2
    assert Features.build(r, appointment(icd10: ["S83.2"]), o, cpt).icd_overlap == 0
  end

  test "cpt counts codes in the referral specialty's ranges", %{o: o, cpt: cpt} do
    a = appointment(cpt: ["99203", "29881", "93000"])
    assert Features.build(referral(), a, o, cpt).cpt_in_referral_family == 2
    assert Features.build(referral(specialty: "dermatology"), a, o, cpt).cpt_in_referral_family == nil
  end

  test "to_candidate stringifies atoms but keeps booleans, nil and numbers" do
    assert Features.to_candidate(%{a: :agree, b: true, c: nil, d: 3, e: false}) ==
             %{a: "agree", b: true, c: nil, d: 3, e: false}
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `mix test test/appointment_referral_link/features_test.exs`
Expected: FAIL. `CptFamilies.load/1 is undefined`.

- [ ] **Step 4: Implement CptFamilies**

```elixir
defmodule AppointmentReferralLink.CptFamilies do
  @moduledoc """
  Specialty to CPT code ranges, shipped as data:
  `{"format": 1, "families": {"orthopedics": [["20000", "29999"], ...]}}`.
  Ranges are inclusive and compared as same-length strings.
  """

  defstruct families: %{}

  @type t :: %__MODULE__{families: %{String.t() => [{String.t(), String.t()}]}}

  @spec default_path() :: Path.t()
  def default_path,
    do: Application.app_dir(:appointment_referral_link, "priv/codes/specialty_cpt.json")

  @spec load(Path.t()) :: {:ok, t()} | {:error, {:cpt_families, Path.t(), term()}}
  def load(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"format" => 1, "families" => families}} when is_map(families) <- JSON.decode(body) do
      {:ok, %__MODULE__{families: Map.new(families, fn {s, ranges} -> {norm(s), parse(ranges)} end)}}
    else
      {:error, reason} -> {:error, {:cpt_families, path, reason}}
      _ -> {:error, {:cpt_families, path, :invalid_format}}
    end
  rescue
    _ in [FunctionClauseError, MatchError] -> {:error, {:cpt_families, path, :invalid_format}}
  end

  @doc "Number of `codes` inside the specialty's ranges; nil when unmapped or no codes."
  @spec count(t(), String.t() | nil, [String.t()] | nil) :: non_neg_integer() | nil
  def count(_t, nil, _codes), do: nil
  def count(_t, _specialty, codes) when codes in [nil, []], do: nil

  def count(%__MODULE__{families: families}, specialty, codes) do
    case Map.fetch(families, norm(specialty)) do
      :error -> nil
      {:ok, ranges} -> Enum.count(codes, &in_ranges?(String.trim(&1), ranges))
    end
  end

  defp parse(ranges), do: Enum.map(ranges, fn [lo, hi] when is_binary(lo) and is_binary(hi) -> {lo, hi} end)

  defp in_ranges?(code, ranges),
    do: Enum.any?(ranges, fn {lo, hi} -> byte_size(code) == byte_size(lo) and code >= lo and code <= hi end)

  defp norm(s), do: s |> String.trim() |> String.downcase()
end
```

- [ ] **Step 5: Implement Features**

```elixir
defmodule AppointmentReferralLink.Features do
  @moduledoc """
  One flat feature map per pair. Values are atoms, numbers, booleans or
  nil; missing values stay nil and are never imputed. Laterality must
  already be filled (see `Laterality.fill/2`) before calling `build/4`.
  """

  alias AppointmentReferralLink.{Appointment, CptFamilies, Gate, Laterality, Ontology, Referral}

  @names [
    :days_from_issue,
    :days_from_auth_start,
    :days_to_auth_end,
    :specialty_match,
    :subspecialty_match,
    :body_part_match,
    :laterality_match,
    :icd_overlap,
    :cpt_in_referral_family,
    :same_referring_provider,
    :booked_from_referral,
    :appointment_status,
    :site_match,
    :already_linked,
    :laterality_missing,
    :body_part_missing,
    :specialty_missing,
    :icd_missing
  ]

  @spec names() :: [atom()]
  def names, do: @names

  @spec build(Referral.t(), Appointment.t(), Ontology.t(), CptFamilies.t()) :: map()
  def build(%Referral{} = r, %Appointment{} = a, ontology, cpt) do
    %{
      days_from_issue: diff(a.starts_on, r.issued_on),
      days_from_auth_start: diff(a.starts_on, r.auth_start),
      days_to_auth_end: diff(r.auth_end, a.starts_on),
      specialty_match: specialty_match(r, a),
      subspecialty_match: Ontology.match(ontology, a.subspecialty, r.body_part),
      body_part_match: Ontology.match(ontology, a.body_part, r.body_part),
      laterality_match: Laterality.compare(r.laterality, a.laterality),
      icd_overlap: icd_overlap(r.icd10, a.icd10),
      cpt_in_referral_family: CptFamilies.count(cpt, r.specialty, a.cpt),
      same_referring_provider: same(r.referring_provider_id, a.rendering_provider_id),
      booked_from_referral: a.booked_from_referral,
      appointment_status: a.status,
      site_match: same(r.site_id, a.site_id),
      already_linked: Gate.Window.linked_elsewhere?(r, a),
      laterality_missing: is_nil(r.laterality) or is_nil(a.laterality),
      body_part_missing: is_nil(r.body_part) or is_nil(a.body_part),
      specialty_missing: is_nil(r.specialty) or is_nil(a.specialty),
      icd_missing: empty?(r.icd10) or empty?(a.icd10)
    }
  end

  @doc """
  The feature map as a `rule_match` candidate. `rule_match` compares
  atoms and strings as different values, so atom values (other than
  booleans and nil) become strings.
  """
  @spec to_candidate(map()) :: map()
  def to_candidate(features), do: Map.new(features, fn {k, v} -> {k, encode(v)} end)

  defp encode(v) when is_boolean(v) or is_nil(v), do: v
  defp encode(v) when is_atom(v), do: Atom.to_string(v)
  defp encode(v), do: v

  defp diff(%Date{} = a, %Date{} = b), do: Date.diff(a, b)
  defp diff(_, _), do: nil

  defp specialty_match(%{specialty: rs}, %{specialty: as}) when is_nil(rs) or is_nil(as), do: nil

  defp specialty_match(r, a) do
    s = norm(a.specialty)

    cond do
      s == norm(r.specialty) -> :exact
      s in Enum.map(r.allowed_specialties || [], &norm/1) -> :allowed
      true -> :mismatch
    end
  end

  defp icd_overlap(r, a) do
    if empty?(r) or empty?(a) do
      nil
    else
      appointment_categories = categories(a)
      r |> categories() |> Enum.count(&MapSet.member?(appointment_categories, &1))
    end
  end

  defp categories(codes),
    do: codes |> Enum.map(&(&1 |> String.trim() |> String.upcase() |> String.slice(0, 3))) |> MapSet.new()

  defp same(nil, _), do: nil
  defp same(_, nil), do: nil
  defp same(a, b), do: a == b

  defp empty?(list), do: list in [nil, []]

  defp norm(s), do: s |> String.trim() |> String.downcase()
end
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `mix test test/appointment_referral_link/features_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add priv/codes lib/appointment_referral_link/cpt_families.ex lib/appointment_referral_link/features.ex test/appointment_referral_link/features_test.exs
git commit -m "feat: pair features with missingness flags and CPT families"
```

---

### Task 7: Ruleset loader and conflict gate

**Files:**
- Create: `lib/appointment_referral_link/rules.ex`
- Create: `priv/rules/conflicts.json`
- Create: `lib/appointment_referral_link/gate/conflict.ex`
- Test: `test/appointment_referral_link/gate/conflict_test.exs`

**Interfaces:**
- Consumes: `Features.build/4`, `Features.to_candidate/1`
- Produces:
  - `Rules.load(nil | Path.t() | %RuleMatch.Ruleset{}, default_path) :: {:ok, Ruleset.t()} | {:error, {:ruleset, path, reason}}`
  - `Rules.priv(relative) :: Path.t()`
  - `Gate.Conflict.default_path()`
  - `Gate.Conflict.load(nil | Path.t() | Ruleset.t())`
  - `Gate.Conflict.check(features, Ruleset.t(), extra_reasons :: [atom()]) :: {[atom()], [rule_id]}`

- [ ] **Step 1: Create the conflict ruleset**

`priv/rules/conflicts.json`:

```json
{
  "format": 1,
  "name": "conflicts",
  "version": "2026-10-08",
  "description": "Hard conflicts. Any matching rule rejects the pair with its outcome reason.",
  "rules": [
    {
      "id": "laterality_conflict",
      "priority": 10,
      "conditions": [{"op": "eq", "field": "laterality_match", "value": "conflict"}],
      "outcome": {"reason": "laterality_conflict"}
    },
    {
      "id": "specialty_mismatch",
      "priority": 10,
      "conditions": [{"op": "eq", "field": "specialty_match", "value": "mismatch"}],
      "outcome": {"reason": "specialty_mismatch"}
    }
  ]
}
```

- [ ] **Step 2: Write the failing test**

```elixir
defmodule AppointmentReferralLink.Gate.ConflictTest do
  use ExUnit.Case, async: true

  import AppointmentReferralLink.Fixtures
  alias AppointmentReferralLink.{CptFamilies, Features, Gate.Conflict, Ontology}

  setup do
    {:ok, o} = Ontology.load([Ontology.default_path()])
    {:ok, cpt} = CptFamilies.load(CptFamilies.default_path())
    {:ok, rules} = Conflict.load(nil)
    features = fn r, a -> Features.build(r, a, o, cpt) end
    %{features: features, rules: rules}
  end

  test "clean pair has no conflicts", %{features: f, rules: rules} do
    assert {[], []} = Conflict.check(f.(referral(), appointment()), rules, [])
  end

  test "laterality conflict", %{features: f, rules: rules} do
    assert {[:laterality_conflict], ["laterality_conflict"]} =
             Conflict.check(f.(referral(), appointment(laterality: :left)), rules, [])
  end

  test "specialty mismatch and laterality together", %{features: f, rules: rules} do
    {reasons, _} =
      Conflict.check(f.(referral(), appointment(laterality: :left, specialty: "cardiology")), rules, [])

    assert Enum.sort(reasons) == [:laterality_conflict, :specialty_mismatch]
  end

  test "missing laterality or specialty is not a conflict", %{features: f, rules: rules} do
    assert {[], _} = Conflict.check(f.(referral(laterality: nil), appointment(laterality: :left)), rules, [])
    assert {[], _} = Conflict.check(f.(referral(), appointment(specialty: nil)), rules, [])
  end

  test "site rules map known reasons, and unknown reasons become :conflict_rule", %{features: f} do
    site =
      RuleMatch.Ruleset.from_json(~s({"format": 1, "rules": [
        {"id": "unbooked_mismatch", "conditions": [
          {"op": "eq", "field": "booked_from_referral", "value": false},
          {"op": "eq", "field": "body_part_match", "value": "mismatch"}],
         "outcome": {"reason": "unbooked_body_mismatch"}},
        {"id": "odd", "conditions": [{"op": "eq", "field": "booked_from_referral", "value": false}],
         "outcome": {"reason": "never_seen_atom_xyz"}}]}))

    {:ok, site} = site
    pair = f.(referral(), appointment(booked_from_referral: false, body_part: "shoulder"))

    assert {reasons, ids} = Conflict.check(pair, site, [:unbooked_body_mismatch])
    assert Enum.sort(reasons) == [:conflict_rule, :unbooked_body_mismatch]
    assert Enum.sort(ids) == ["odd", "unbooked_mismatch"]
  end

  test "load/1 reports a missing file" do
    assert {:error, {:ruleset, "/nope.json", :enoent}} = Conflict.load("/nope.json")
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `mix test test/appointment_referral_link/gate/conflict_test.exs`
Expected: FAIL. `Conflict.load/1 is undefined`.

- [ ] **Step 4: Implement Rules**

```elixir
defmodule AppointmentReferralLink.Rules do
  @moduledoc false
  # Loads rule_match rulesets straight from JSON files, so the host's
  # `:rule_match` adapter configuration (e.g. Ecto) is never consulted.

  @spec load(nil | Path.t() | RuleMatch.Ruleset.t(), Path.t()) ::
          {:ok, RuleMatch.Ruleset.t()} | {:error, {:ruleset, Path.t(), term()}}
  def load(nil, default), do: load(default, default)
  def load(%RuleMatch.Ruleset{} = ruleset, _default), do: {:ok, ruleset}

  def load(path, _default) when is_binary(path) do
    with {:ok, json} <- File.read(path),
         {:ok, ruleset} <- RuleMatch.Ruleset.from_json(json) do
      {:ok, ruleset}
    else
      {:error, reason} -> {:error, {:ruleset, path, reason}}
    end
  end

  @spec priv(Path.t()) :: Path.t()
  def priv(relative), do: Application.app_dir(:appointment_referral_link, relative)
end
```

- [ ] **Step 5: Implement Gate.Conflict**

```elixir
defmodule AppointmentReferralLink.Gate.Conflict do
  @moduledoc """
  Hard conflicts as a `rule_match` ruleset over the feature map. Every
  matching rule rejects the pair with its outcome `reason`. Reasons
  map to atoms through an allow-list (the shipped reasons plus
  `:conflict_reasons` from config); anything else becomes
  `:conflict_rule`, so no atoms are created from data.
  """

  alias AppointmentReferralLink.{Features, Rules}

  @known [:laterality_conflict, :specialty_mismatch]

  @spec default_path() :: Path.t()
  def default_path, do: Rules.priv("priv/rules/conflicts.json")

  @spec load(nil | Path.t() | RuleMatch.Ruleset.t()) ::
          {:ok, RuleMatch.Ruleset.t()} | {:error, term()}
  def load(source), do: Rules.load(source, default_path())

  @spec check(map(), RuleMatch.Ruleset.t(), [atom()]) :: {[atom()], [String.t()]}
  def check(features, ruleset, extra_reasons) do
    {:ok, matches} = RuleMatch.match(ruleset, Features.to_candidate(features))
    allowed = @known ++ extra_reasons
    reasons = matches |> Enum.map(&reason(&1.outcome, allowed)) |> Enum.uniq()
    {reasons, Enum.map(matches, & &1.rule.id)}
  end

  defp reason(%{reason: r}, allowed) when is_binary(r),
    do: Enum.find(allowed, :conflict_rule, &(Atom.to_string(&1) == r))

  defp reason(_outcome, _allowed), do: :conflict_rule
end
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `mix test test/appointment_referral_link/gate/conflict_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add priv/rules/conflicts.json lib/appointment_referral_link/rules.ex lib/appointment_referral_link/gate/conflict.ex test/appointment_referral_link/gate/conflict_test.exs
git commit -m "feat: rule_match conflict gate with reason allow-list"
```

---

### Task 8: Scorer behaviour and rules-based scorer

**Files:**
- Create: `lib/appointment_referral_link/score.ex`
- Create: `priv/rules/score_weights.json`
- Create: `lib/appointment_referral_link/score/rules.ex`
- Test: `test/appointment_referral_link/score/rules_test.exs`

**Interfaces:**
- Consumes: `Rules.load/2`, `Features.to_candidate/1`, `Config`
- Produces:
  - Behaviour `AppointmentReferralLink.Score` with callbacks `init/1` and `score/2` (signatures below)
  - `Score.Rules.init(Config.t()) :: {:ok, %{ruleset, intercept}} | {:error, term}`
  - `Score.Rules.score(features, state) :: {:ok, float, %{logit: float, rules: [String.t()]}} | {:error, term}`
  - `Score.Rules.logistic(number) :: float`

- [ ] **Step 1: Create the behaviour**

```elixir
defmodule AppointmentReferralLink.Score do
  @moduledoc """
  Structured scorer. `init/1` runs once per `link/3` / `evaluate/2` call
  and loads whatever the scorer needs; `score/2` returns a probability in
  [0, 1] and a details map stored as `components.score`. Errors and
  exceptions turn the pair into `:review`.
  """

  @callback init(AppointmentReferralLink.Config.t()) :: {:ok, term()} | {:error, term()}
  @callback score(features :: map(), state :: term()) ::
              {:ok, float(), map()} | {:error, term()}
end
```

- [ ] **Step 2: Create the weights**

`priv/rules/score_weights.json`. With intercept -4.0, the strongest
profile sums to logit 3.1, which gives p ≈ 0.957 and links. Dropping any
single positive rule of 0.8 or more gives p ≤ 0.917, which is review.

```json
{
  "format": 1,
  "name": "score_weights",
  "version": "2026-10-08",
  "description": "Hand-set conservative weights. p = logistic(intercept + sum of matched weights).",
  "meta": {"intercept": -4.0},
  "rules": [
    {"id": "specialty_exact", "conditions": [{"op": "eq", "field": "specialty_match", "value": "exact"}], "outcome": {"weight": 1.5}},
    {"id": "specialty_allowed", "conditions": [{"op": "eq", "field": "specialty_match", "value": "allowed"}], "outcome": {"weight": 0.8}},
    {"id": "body_part_agree", "conditions": [{"op": "in", "field": "body_part_match", "values": ["exact", "related"]}], "outcome": {"weight": 1.5}},
    {"id": "body_part_mismatch", "conditions": [{"op": "eq", "field": "body_part_match", "value": "mismatch"}], "outcome": {"weight": -2.0}},
    {"id": "laterality_agree", "conditions": [{"op": "eq", "field": "laterality_match", "value": "agree"}], "outcome": {"weight": 1.0}},
    {"id": "booked_from_referral", "conditions": [{"op": "eq", "field": "booked_from_referral", "value": true}], "outcome": {"weight": 1.5}},
    {"id": "icd_overlap", "conditions": [{"op": "gte", "field": "icd_overlap", "value": 1}], "outcome": {"weight": 0.8}},
    {"id": "near_issue", "conditions": [{"op": "between", "field": "days_from_issue", "from": 0, "to": 30}], "outcome": {"weight": 0.8}},
    {"id": "late_after_issue", "conditions": [{"op": "gt", "field": "days_from_issue", "value": 60}], "outcome": {"weight": -1.0}}
  ]
}
```

- [ ] **Step 3: Write the failing test**

```elixir
defmodule AppointmentReferralLink.Score.RulesTest do
  use ExUnit.Case, async: true

  import AppointmentReferralLink.Fixtures
  alias AppointmentReferralLink.{Config, CptFamilies, Features, Ontology, Score}

  setup do
    {:ok, c} = Config.build([])
    {:ok, state} = Score.Rules.init(c)
    {:ok, o} = Ontology.load([Ontology.default_path()])
    {:ok, cpt} = CptFamilies.load(CptFamilies.default_path())
    %{state: state, f: fn r, a -> Features.build(r, a, o, cpt) end}
  end

  test "logistic arithmetic" do
    assert Score.Rules.logistic(0) == 0.5
    assert_in_delta Score.Rules.logistic(3.1), 0.9569, 0.0001
  end

  test "strongest profile clears link_at", %{state: s, f: f} do
    assert {:ok, p, %{logit: logit, rules: rules}} = Score.Rules.score(f.(referral(), appointment()), s)
    assert_in_delta logit, 3.1, 1.0e-9
    assert p > 0.92

    assert Enum.sort(rules) ==
             ~w(body_part_agree booked_from_referral icd_overlap laterality_agree near_issue specialty_exact)
  end

  test "dropping ICD overlap lands in the review band", %{state: s, f: f} do
    {:ok, p, _} = Score.Rules.score(f.(referral(), appointment(icd10: ["S83.2"])), s)
    assert p > 0.35 and p < 0.92
  end

  test "nil ICD does not count as overlap", %{state: s, f: f} do
    {:ok, _, %{rules: rules}} = Score.Rules.score(f.(referral(), appointment(icd10: [])), s)
    refute "icd_overlap" in rules
  end

  test "body-part mismatch without booking scores below reject_at", %{state: s, f: f} do
    a = appointment(body_part: "shoulder", booked_from_referral: false, icd10: ["M75.100"])
    {:ok, p, _} = Score.Rules.score(f.(referral(), a), s)
    assert p < 0.35
  end

  @tag :tmp_dir
  test "init rejects a ruleset without a numeric intercept", %{tmp_dir: dir} do
    path = Path.join(dir, "w.json")
    File.write!(path, ~s({"format": 1, "rules": []}))
    {:ok, c} = Config.build(score_rules: path)
    assert {:error, {:score_rules, _}} = Score.Rules.init(c)
  end

  @tag :tmp_dir
  test "a rule without a numeric weight is a score error", %{tmp_dir: dir, f: f} do
    path = Path.join(dir, "w.json")

    File.write!(path, ~s({"format": 1, "meta": {"intercept": 0},
      "rules": [{"id": "bad", "conditions": [], "outcome": {"weight": "high"}}]}))

    {:ok, c} = Config.build(score_rules: path)
    {:ok, s} = Score.Rules.init(c)
    assert {:error, {:bad_weight, "bad"}} = Score.Rules.score(f.(referral(), appointment()), s)
  end
end
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `mix test test/appointment_referral_link/score/rules_test.exs`
Expected: FAIL. `Score.Rules.init/1 is undefined`.

- [ ] **Step 5: Implement Score.Rules**

```elixir
defmodule AppointmentReferralLink.Score.Rules do
  @moduledoc """
  Default scorer: a `rule_match` ruleset whose rule outcomes carry
  `weight`, plus `meta.intercept`. Every matching rule's weight is summed
  and passed through the logistic function. Swap the file with
  `:score_rules`.
  """

  @behaviour AppointmentReferralLink.Score

  alias AppointmentReferralLink.{Config, Features, Rules}

  @spec default_path() :: Path.t()
  def default_path, do: Rules.priv("priv/rules/score_weights.json")

  @impl true
  def init(%Config{score_rules: source}) do
    with {:ok, ruleset} <- Rules.load(source, default_path()) do
      case ruleset.meta do
        %{"intercept" => i} when is_number(i) -> {:ok, %{ruleset: ruleset, intercept: i}}
        _ -> {:error, {:score_rules, "meta.intercept must be a number"}}
      end
    end
  end

  @impl true
  def score(features, %{ruleset: ruleset, intercept: intercept}) do
    {:ok, matches} = RuleMatch.match(ruleset, Features.to_candidate(features))

    with {:ok, weights} <- weights(matches) do
      logit = intercept + Enum.sum(weights)
      {:ok, logistic(logit), %{logit: logit, rules: Enum.map(matches, & &1.rule.id)}}
    end
  end

  @spec logistic(number()) :: float()
  def logistic(x), do: 1.0 / (1.0 + :math.exp(-x))

  defp weights(matches) do
    Enum.reduce_while(matches, {:ok, []}, fn %{outcome: outcome, rule: rule}, {:ok, acc} ->
      case outcome do
        %{weight: w} when is_number(w) -> {:cont, {:ok, [w | acc]}}
        _ -> {:halt, {:error, {:bad_weight, rule.id}}}
      end
    end)
  end
end
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `mix test test/appointment_referral_link/score/rules_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add priv/rules/score_weights.json lib/appointment_referral_link/score.ex lib/appointment_referral_link/score/rules.ex test/appointment_referral_link/score/rules_test.exs
git commit -m "feat: scorer behaviour and rule_match weighted scorer"
```

---

### Task 9: Text adapter behaviour and threshold

**Files:**
- Create: `lib/appointment_referral_link/score/text.ex`
- Create: `lib/appointment_referral_link/score/text/none.ex`
- Create: `lib/appointment_referral_link/threshold.ex`
- Test: `test/appointment_referral_link/threshold_test.exs`

**Interfaces:**
- Produces:
  - Behaviour `Score.Text` with `refine(Referral.t(), Appointment.t(), features, p, Config.t()) :: {:ok, float} | {:error, term}`
  - `Score.Text.None.refine/5`, which returns `{:ok, p}`
  - `Threshold.in_band?(p, Config.t()) :: boolean`
  - `Threshold.outcome(p, Config.t()) :: :link | :reject | :review`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule AppointmentReferralLink.ThresholdTest do
  use ExUnit.Case, async: true

  alias AppointmentReferralLink.{Config, Score.Text.None, Threshold}

  setup do
    {:ok, c} = Config.build([])
    %{c: c}
  end

  test "outcome", %{c: c} do
    assert Threshold.outcome(0.92, c) == :link
    assert Threshold.outcome(0.99, c) == :link
    assert Threshold.outcome(0.91, c) == :review
    assert Threshold.outcome(0.35, c) == :review
    assert Threshold.outcome(0.34, c) == :reject
  end

  test "band is inclusive", %{c: c} do
    assert Threshold.in_band?(0.35, c)
    assert Threshold.in_band?(0.92, c)
    refute Threshold.in_band?(0.34, c)
    refute Threshold.in_band?(0.95, c)
  end

  test "None leaves the score unchanged", %{c: c} do
    assert None.refine(nil, nil, %{}, 0.5, c) == {:ok, 0.5}
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/appointment_referral_link/threshold_test.exs`
Expected: FAIL. `Threshold.outcome/2 is undefined`.

- [ ] **Step 3: Implement**

`lib/appointment_referral_link/score/text.ex`:

```elixir
defmodule AppointmentReferralLink.Score.Text do
  @moduledoc """
  Text residual for pairs whose structured score sits in the review band.
  The pipeline calls `refine/5` under `text_timeout`; an error, exception,
  or timeout sends the pair to `:review`, never `:link`. The adapter can
  never overturn a gate: gated pairs never reach it.
  """

  alias AppointmentReferralLink.{Appointment, Config, Referral}

  @callback refine(Referral.t(), Appointment.t(), features :: map(), p :: float(), Config.t()) ::
              {:ok, float()} | {:error, term()}
end
```

`lib/appointment_referral_link/score/text/none.ex`:

```elixir
defmodule AppointmentReferralLink.Score.Text.None do
  @moduledoc "Text adapter that leaves the structured score unchanged."

  @behaviour AppointmentReferralLink.Score.Text

  @impl true
  def refine(_referral, _appointment, _features, p, _config), do: {:ok, p}
end
```

`lib/appointment_referral_link/threshold.ex`:

```elixir
defmodule AppointmentReferralLink.Threshold do
  @moduledoc "Turns a final probability into an outcome. The only place `:link` comes from."

  alias AppointmentReferralLink.Config

  @spec in_band?(float(), Config.t()) :: boolean()
  def in_band?(p, %Config{review_low: low, review_high: high}), do: p >= low and p <= high

  @spec outcome(float(), Config.t()) :: :link | :reject | :review
  def outcome(p, %Config{link_at: link_at, reject_at: reject_at}) do
    cond do
      p >= link_at -> :link
      p < reject_at -> :reject
      true -> :review
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/appointment_referral_link/threshold_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/appointment_referral_link/score/text.ex lib/appointment_referral_link/score/text lib/appointment_referral_link/threshold.ex test/appointment_referral_link/threshold_test.exs
git commit -m "feat: text adapter behaviour with None adapter, and thresholds"
```

---

### Task 10: Pipeline and `link/3`

**Files:**
- Create: `lib/appointment_referral_link/pipeline.ex`
- Modify: `lib/appointment_referral_link.ex`
- Create: `test/support/stubs.ex`
- Test: `test/appointment_referral_link_test.exs`

**Interfaces:**
- Consumes: everything from Tasks 1–9
- Produces:
  - `Pipeline.prepare(Config.t()) :: {:ok, Config.t()} | {:error, term}`
  - `Pipeline.run(Referral.t(), Appointment.t(), Config.t()) :: Decision.t()`
  - `AppointmentReferralLink.link(Referral.t(), [Appointment.t()], keyword) :: {:ok, [Decision.t()]} | {:error, term}`
  - Test stubs `AppointmentReferralLink.Stubs.{HighScorer, MidScorer, RaisingScorer, BadScorer, IntScorer, HighText, LowText, SlowText, RaisingText}`

- [ ] **Step 1: Create the stubs**

`test/support/stubs.ex`:

```elixir
defmodule AppointmentReferralLink.Stubs do
  @moduledoc false

  defmodule HighScorer do
    @moduledoc false
    @behaviour AppointmentReferralLink.Score
    @impl true
    def init(_config), do: {:ok, nil}
    @impl true
    def score(_features, _state), do: {:ok, 0.99, %{}}
  end

  defmodule MidScorer do
    @moduledoc false
    @behaviour AppointmentReferralLink.Score
    @impl true
    def init(_config), do: {:ok, nil}
    @impl true
    def score(_features, _state), do: {:ok, 0.6, %{}}
  end

  defmodule RaisingScorer do
    @moduledoc false
    @behaviour AppointmentReferralLink.Score
    @impl true
    def init(_config), do: {:ok, nil}
    @impl true
    def score(_features, _state), do: raise("scorer down")
  end

  defmodule BadScorer do
    @moduledoc false
    @behaviour AppointmentReferralLink.Score
    @impl true
    def init(_config), do: {:ok, nil}
    @impl true
    def score(_features, _state), do: {:ok, 1.5, %{}}
  end

  defmodule IntScorer do
    @moduledoc false
    @behaviour AppointmentReferralLink.Score
    @impl true
    def init(_config), do: {:ok, nil}
    @impl true
    def score(_features, _state), do: {:ok, 1, %{}}
  end

  defmodule HighText do
    @moduledoc false
    @behaviour AppointmentReferralLink.Score.Text
    @impl true
    def refine(_r, _a, _f, _p, _c), do: {:ok, 0.99}
  end

  defmodule LowText do
    @moduledoc false
    @behaviour AppointmentReferralLink.Score.Text
    @impl true
    def refine(_r, _a, _f, _p, _c), do: {:ok, 0.1}
  end

  defmodule SlowText do
    @moduledoc false
    @behaviour AppointmentReferralLink.Score.Text
    @impl true
    def refine(_r, _a, _f, _p, _c) do
      Process.sleep(1_000)
      {:ok, 0.99}
    end
  end

  defmodule RaisingText do
    @moduledoc false
    @behaviour AppointmentReferralLink.Score.Text
    @impl true
    def refine(_r, _a, _f, _p, _c), do: raise("text service down")
  end
end
```

- [ ] **Step 2: Write the failing test**

`test/appointment_referral_link_test.exs`:

```elixir
defmodule AppointmentReferralLinkTest do
  use ExUnit.Case, async: true

  import AppointmentReferralLink.Fixtures
  alias AppointmentReferralLink.{Decision, Stubs}

  @band [review_low: 0.0, review_high: 1.0]

  test "clean pair links with a trace" do
    assert {:ok, [%Decision{} = d]} = AppointmentReferralLink.link(referral(), [appointment()])
    assert d.outcome == :link
    assert d.reasons == [:score]
    assert d.appointment_id == "appt_1"
    assert d.referral_id == "ref_1"
    assert d.score > 0.92
    assert d.components.features.laterality_match == :agree
    assert d.components.scorer == AppointmentReferralLink.Score.Rules
    assert "booked_from_referral" in d.components.score.rules
  end

  test "one decision per appointment, in input order" do
    appts = [appointment(id: "a"), appointment(id: "b", laterality: :left), appointment(id: "c", patient_id: "x")]
    {:ok, decisions} = AppointmentReferralLink.link(referral(), appts)

    assert Enum.map(decisions, &{&1.appointment_id, &1.outcome, &1.reasons}) == [
             {"a", :link, [:score]},
             {"b", :reject, [:laterality_conflict]},
             {"c", :reject, [:patient_mismatch]}
           ]
  end

  test "gate rejections carry no score" do
    {:ok, [d]} = AppointmentReferralLink.link(referral(), [appointment(status: :cancelled)])
    assert d.outcome == :reject
    assert d.score == nil
    assert d.reasons == [:status_excluded]
  end

  test "laterality filled from reason text triggers the conflict gate" do
    {:ok, [d]} = AppointmentReferralLink.link(referral(), [appointment(laterality: nil, reason: "lt knee")])
    assert d.reasons == [:laterality_conflict]
    assert d.components.features.laterality_match == :conflict
  end

  test "empty appointment list" do
    assert {:ok, []} = AppointmentReferralLink.link(referral(), [])
  end

  test "invalid input" do
    assert {:error, {:invalid_input, _}} = AppointmentReferralLink.link(referral(), [%{id: "x"}])
    assert {:error, {:invalid_input, _}} = AppointmentReferralLink.link(%{id: "r"}, [])
  end

  test "invalid config and missing data files are errors" do
    assert {:error, {:invalid_config, _}} = AppointmentReferralLink.link(referral(), [], reject_at: 0.99)
    assert {:error, {:ruleset, _, _}} = AppointmentReferralLink.link(referral(), [], conflict_rules: "/nope.json")
    assert {:error, {:ontology, _, _}} = AppointmentReferralLink.link(referral(), [], ontology_paths: ["/nope.json"])
  end

  describe "scorer failures go to review, never link" do
    for scorer <- [Stubs.RaisingScorer, Stubs.BadScorer, Stubs.IntScorer] do
      test "#{inspect(scorer)}" do
        {:ok, [d]} = AppointmentReferralLink.link(referral(), [appointment()], scorer: unquote(scorer))
        assert d.outcome == :review
        assert d.reasons == [:scorer_error]
        assert d.score == nil
      end
    end
  end

  describe "text adapter" do
    test "is skipped outside the band" do
      {:ok, [d]} = AppointmentReferralLink.link(referral(), [appointment()], text_adapter: Stubs.LowText)
      assert d.outcome == :link
      refute Map.has_key?(d.components, :text)
    end

    test "replaces the score inside the band" do
      opts = [scorer: Stubs.MidScorer, text_adapter: Stubs.LowText]
      {:ok, [d]} = AppointmentReferralLink.link(referral(), [appointment()], opts)
      assert d.outcome == :reject
      assert d.score == 0.1
      assert d.components.text == %{before: 0.6, after: 0.1}
    end

    test "timeout produces review, not link" do
      opts = @band ++ [text_adapter: Stubs.SlowText, text_timeout: 50]
      {:ok, [d]} = AppointmentReferralLink.link(referral(), [appointment()], opts)
      assert d.outcome == :review
      assert d.reasons == [:text_unavailable]
      assert d.components.text == %{error: :timeout}
    end

    test "an exception produces review, not link" do
      opts = @band ++ [text_adapter: Stubs.RaisingText]
      {:ok, [d]} = AppointmentReferralLink.link(referral(), [appointment()], opts)
      assert d.outcome == :review
      assert d.reasons == [:text_unavailable]
    end
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `mix test test/appointment_referral_link_test.exs`
Expected: FAIL. `AppointmentReferralLink.link/2 is undefined`.

- [ ] **Step 4: Implement Pipeline**

```elixir
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
       %{c | ontology: ontology, conflicts: conflicts, cpt_table: cpt, fs_model: fs_model, scorer_state: scorer_state}}
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

  defp call_text(r, a, features, p, c) do
    task =
      Task.async(fn ->
        try do
          c.text_adapter.refine(r, a, features, p, c)
        rescue
          e -> {:error, {:exception, Exception.message(e)}}
        catch
          kind, value -> {:error, {kind, value}}
        end
      end)

    case Task.yield(task, c.text_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, refined}} when is_float(refined) and refined >= 0.0 and refined <= 1.0 -> {:ok, refined}
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, other} -> {:error, {:bad_return, other}}
      {:exit, reason} -> {:error, {:exit, reason}}
      nil -> {:error, :timeout}
    end
  end

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
```

- [ ] **Step 5: Implement `link/3`**

`lib/appointment_referral_link.ex`:

```elixir
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
```

- [ ] **Step 6: Run the whole suite**

Run: `mix test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/appointment_referral_link.ex lib/appointment_referral_link/pipeline.ex test/support/stubs.ex test/appointment_referral_link_test.exs
git commit -m "feat: pipeline and link/3 with scorer and text failure handling"
```

---

### Task 11: Optional ONNX tree scorer

**Files:**
- Modify: `mix.exs` (add the Ortex dep)
- Create: `lib/appointment_referral_link/score/tree/encoder.ex`
- Create: `lib/appointment_referral_link/score/tree.ex`
- Create: `scripts/make_test_tree.py`
- Create: `test/fixtures/models/linker.onnx`, `test/fixtures/models/linker.features.json` (generated)
- Test: `test/appointment_referral_link/score/tree_test.exs`

**Interfaces:**
- Consumes: `Features.to_candidate/1`, `Features.names/0`, `Rules.priv/1`, `Config` (`tree_model_path`, `tree_columns_path`)
- Produces:
  - `Score.Tree.Encoder.load(Path.t()) :: {:ok, [column]} | {:error, {:tree_columns, path, reason}}`
  - `Score.Tree.Encoder.encode(features, [column]) :: [float | :nan]`
  - `Score.Tree`, which implements `AppointmentReferralLink.Score` and is
    compiled only when `Ortex` is loaded

- [ ] **Step 1: Add the optional dep**

In `mix.exs` `deps/0`, add after `patient_matching`:

```elixir
      {:ortex, "~> 0.1.10", optional: true},
```

Run: `mix deps.get && mix compile`
Expected: Ortex compiles. A Rust toolchain is present at `~/.cargo/bin`.

- [ ] **Step 2: Write the failing encoder test and the tagged model test**

`test/appointment_referral_link/score/tree_test.exs`:

```elixir
defmodule AppointmentReferralLink.Score.TreeTest do
  use ExUnit.Case, async: true

  import AppointmentReferralLink.Fixtures
  alias AppointmentReferralLink.{Config, CptFamilies, Features, Ontology, Score.Tree.Encoder}

  @models Path.expand("../../fixtures/models", __DIR__)

  setup do
    {:ok, o} = Ontology.load([Ontology.default_path()])
    {:ok, cpt} = CptFamilies.load(CptFamilies.default_path())
    %{f: fn r, a -> Features.build(r, a, o, cpt) end}
  end

  @tag :tmp_dir
  test "encodes numerics, booleans, one-hot, and nil as NaN", %{tmp_dir: dir, f: f} do
    path = Path.join(dir, "cols.json")

    File.write!(path, ~s({"format": 1, "columns": [
      {"name": "days_from_issue"},
      {"name": "booked_from_referral"},
      {"name": "laterality_match", "one_hot": ["agree", "conflict", "unknown"]},
      {"name": "icd_overlap"},
      {"name": "specialty_match", "one_hot": ["exact", "allowed", "mismatch"]}]}))

    {:ok, cols} = Encoder.load(path)
    features = f.(referral(), appointment(icd10: [], specialty: nil))

    assert Encoder.encode(features, cols) ==
             [17.0, 1.0, 1.0, 0.0, 0.0, :nan, :nan, :nan, :nan]
  end

  @tag :tmp_dir
  test "rejects unknown column names", %{tmp_dir: dir} do
    path = Path.join(dir, "cols.json")
    File.write!(path, ~s({"format": 1, "columns": [{"name": "days_from_issu"}]}))
    assert {:error, {:tree_columns, ^path, {:unknown_feature, "days_from_issu"}}} = Encoder.load(path)
  end

  @tag :ortex
  test "scores with the fixture model", %{f: f} do
    {:ok, c} =
      Config.build(
        scorer: AppointmentReferralLink.Score.Tree,
        tree_model_path: Path.join(@models, "linker.onnx")
      )

    {:ok, state} = AppointmentReferralLink.Score.Tree.init(c)
    {:ok, booked, _} = AppointmentReferralLink.Score.Tree.score(f.(referral(), appointment()), state)

    {:ok, unbooked, _} =
      AppointmentReferralLink.Score.Tree.score(f.(referral(), appointment(booked_from_referral: false)), state)

    assert booked >= 0.0 and booked <= 1.0
    assert booked > unbooked

    assert {:ok, [d]} =
             AppointmentReferralLink.link(referral(), [appointment()],
               scorer: AppointmentReferralLink.Score.Tree,
               tree_model_path: Path.join(@models, "linker.onnx")
             )

    assert d.outcome in [:link, :review, :reject]
  end

  @tag :ortex
  test "a missing model is an init error" do
    {:ok, c} = Config.build(tree_model_path: "/nope/linker.onnx", tree_columns_path: Path.join(@models, "linker.features.json"))
    assert {:error, {:tree_model, "/nope/linker.onnx", _}} = AppointmentReferralLink.Score.Tree.init(c)
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `mix test test/appointment_referral_link/score/tree_test.exs`
Expected: FAIL. `Encoder.load/1 is undefined`.

- [ ] **Step 4: Implement the encoder**

```elixir
defmodule AppointmentReferralLink.Score.Tree.Encoder do
  @moduledoc """
  Turns a feature map into the fixed numeric row the ONNX model was
  trained on. The column file sits next to the model:

      {"format": 1, "columns": [
        {"name": "days_from_issue"},
        {"name": "laterality_match", "one_hot": ["agree", "conflict", "unknown"]}]}

  Numbers pass through as floats, booleans become 1.0/0.0, categoricals
  become one-hot, and nil becomes NaN (all NaN for a one-hot group).
  """

  alias AppointmentReferralLink.Features

  @type column :: {:numeric, String.t()} | {:one_hot, String.t(), [String.t()]}

  @spec load(Path.t()) :: {:ok, [column()]} | {:error, {:tree_columns, Path.t(), term()}}
  def load(path) do
    known = Enum.map(Features.names(), &Atom.to_string/1)

    with {:ok, body} <- File.read(path),
         {:ok, %{"format" => 1, "columns" => cols}} when is_list(cols) <- JSON.decode(body),
         {:ok, columns} <- columns(cols, known) do
      {:ok, columns}
    else
      {:error, reason} -> {:error, {:tree_columns, path, reason}}
      _ -> {:error, {:tree_columns, path, :invalid_format}}
    end
  end

  @spec encode(map(), [column()]) :: [float() | :nan]
  def encode(features, columns) do
    values = Map.new(Features.to_candidate(features), fn {k, v} -> {Atom.to_string(k), v} end)

    Enum.flat_map(columns, fn
      {:numeric, name} ->
        [numeric(Map.get(values, name))]

      {:one_hot, name, categories} ->
        case Map.get(values, name) do
          nil -> List.duplicate(:nan, length(categories))
          value -> Enum.map(categories, &if(&1 == value, do: 1.0, else: 0.0))
        end
    end)
  end

  defp columns(cols, known) do
    Enum.reduce_while(cols, {:ok, []}, fn col, {:ok, acc} ->
      case column(col) do
        {:ok, {_, name} = c} -> check(name, c, acc, known)
        {:ok, {_, name, _} = c} -> check(name, c, acc, known)
        :error -> {:halt, {:error, {:bad_column, col}}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp check(name, column, acc, known) do
    if name in known,
      do: {:cont, {:ok, [column | acc]}},
      else: {:halt, {:error, {:unknown_feature, name}}}
  end

  defp column(%{"name" => name, "one_hot" => cats}) when is_binary(name) and is_list(cats),
    do: {:ok, {:one_hot, name, cats}}

  defp column(%{"name" => name}) when is_binary(name), do: {:ok, {:numeric, name}}
  defp column(_), do: :error

  defp numeric(nil), do: :nan
  defp numeric(true), do: 1.0
  defp numeric(false), do: 0.0
  defp numeric(n) when is_number(n), do: n * 1.0
  defp numeric(_), do: :nan
end
```

- [ ] **Step 5: Implement the Ortex scorer**

`lib/appointment_referral_link/score/tree.ex`:

```elixir
if Code.ensure_loaded?(Ortex) do
  defmodule AppointmentReferralLink.Score.Tree do
    @moduledoc """
    Gradient-boosted tree exported to ONNX, run through Ortex. Compiled
    only when the optional `:ortex` dependency is present.

    The model must take one float32 input of shape `{n, columns}` and
    return `{label, probabilities}` with probabilities `{n, 2}`. For
    scikit-learn, export with `skl2onnx` and `options={"zipmap": False}`.
    The model is loaded once per path and cached in `:persistent_term`.
    """

    @behaviour AppointmentReferralLink.Score

    alias AppointmentReferralLink.{Config, Rules, Score.Tree.Encoder}

    @impl true
    def init(%Config{} = c) do
      model_path = c.tree_model_path || Rules.priv("priv/models/linker.onnx")
      columns_path = c.tree_columns_path || Path.join(Path.dirname(model_path), "linker.features.json")

      with {:ok, columns} <- Encoder.load(columns_path),
           {:ok, model} <- model(model_path) do
        {:ok, %{model: model, columns: columns, path: model_path}}
      end
    end

    @impl true
    def score(features, %{model: model, columns: columns, path: path}) do
      input = Nx.tensor([Encoder.encode(features, columns)], type: :f32)
      {_label, probabilities} = Ortex.run(model, input)
      p = probabilities |> Nx.to_flat_list() |> Enum.at(1)
      {:ok, p * 1.0, %{model: path, columns: length(columns)}}
    end

    defp model(path) do
      key = {__MODULE__, path}

      case :persistent_term.get(key, nil) do
        nil ->
          if File.exists?(path) do
            model = Ortex.load(path)
            :persistent_term.put(key, model)
            {:ok, model}
          else
            {:error, {:tree_model, path, :enoent}}
          end

        model ->
          {:ok, model}
      end
    rescue
      e -> {:error, {:tree_model, path, Exception.message(e)}}
    end
  end
end
```

- [ ] **Step 6: Write the fixture model generator**

`scripts/make_test_tree.py`:

```python
"""Builds the tiny ONNX fixture used by the :ortex tests. Dev-only.

    python -m venv /tmp/arl && /tmp/arl/bin/pip install scikit-learn skl2onnx numpy
    /tmp/arl/bin/python scripts/make_test_tree.py
"""
import json
from pathlib import Path

import numpy as np
from sklearn.ensemble import GradientBoostingClassifier
from skl2onnx import to_onnx

OUT = Path(__file__).resolve().parent.parent / "test" / "fixtures" / "models"
COLUMNS = [
    {"name": "days_from_issue"},
    {"name": "booked_from_referral"},
    {"name": "icd_overlap"},
    {"name": "laterality_match", "one_hot": ["agree", "conflict", "unknown"]},
]

rng = np.random.default_rng(1)
n = 400
days = rng.integers(-7, 105, n)
booked = rng.integers(0, 2, n)
icd = rng.integers(0, 3, n)
lat = rng.integers(0, 3, n)
lat_onehot = np.eye(3)[lat]
X = np.column_stack([days, booked, icd, lat_onehot]).astype(np.float32)
y = ((booked == 1) & (lat != 1) & (days < 60)).astype(int)

model = GradientBoostingClassifier(n_estimators=20, max_depth=2, random_state=1).fit(X, y)
onx = to_onnx(model, X[:1], options={id(model): {"zipmap": False}}, target_opset=17)

OUT.mkdir(parents=True, exist_ok=True)
(OUT / "linker.onnx").write_bytes(onx.SerializeToString())
(OUT / "linker.features.json").write_text(json.dumps({"format": 1, "columns": COLUMNS}, indent=2) + "\n")
print(f"wrote {OUT}")
```

Run:

```bash
python -m venv /tmp/arl && /tmp/arl/bin/pip install -q scikit-learn skl2onnx numpy
/tmp/arl/bin/python scripts/make_test_tree.py
```

Expected: `test/fixtures/models/linker.onnx` and `linker.features.json` exist.

- [ ] **Step 7: Run the tests, including the `:ortex` tag**

Run: `mix test test/appointment_referral_link/score/tree_test.exs --include ortex`
Expected: PASS for all four tests.

Run: `mix test`
Expected: PASS. The `:ortex` tests are excluded by default.

- [ ] **Step 8: Commit**

```bash
git add mix.exs mix.lock lib/appointment_referral_link/score/tree.ex lib/appointment_referral_link/score/tree scripts/make_test_tree.py test/fixtures/models test/appointment_referral_link/score/tree_test.exs
git commit -m "feat: optional Ortex ONNX tree scorer with feature encoder"
```

---

### Task 12: `evaluate/2` and Report

**Files:**
- Modify: `lib/appointment_referral_link/report.ex` (add `build/1`)
- Modify: `lib/appointment_referral_link.ex` (add `evaluate/2`)
- Test: `test/appointment_referral_link/evaluate_test.exs`

**Interfaces:**
- Consumes: `Config.build/1`, `Pipeline.prepare/1`, `Pipeline.run/3`
- Produces:
  - `Report.build([{outcome, label :: boolean, cross? :: boolean}]) :: Report.t()`
  - `AppointmentReferralLink.evaluate([%{referral:, appointment:, label:}], keyword) :: Report.t()`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule AppointmentReferralLink.EvaluateTest do
  use ExUnit.Case, async: true

  import AppointmentReferralLink.Fixtures
  alias AppointmentReferralLink.Report

  test "Report.build/1 arithmetic" do
    report =
      Report.build([
        {:link, true, false},
        {:link, false, true},
        {:review, true, false},
        {:reject, false, false}
      ])

    assert report.total == 4
    assert report.precision == 0.5
    assert report.recall == 0.5
    assert report.review_rate == 0.25
    assert report.cross_referral_false_link_rate == 0.5
    assert report.counts == %{{:link, true} => 1, {:link, false} => 1, {:review, true} => 1, {:reject, false} => 1}
  end

  test "empty and link-free reports" do
    assert %Report{total: 0, precision: nil, recall: nil, review_rate: nil, cross_referral_false_link_rate: 0.0} =
             Report.build([])

    assert %Report{precision: nil, cross_referral_false_link_rate: 0.0} = Report.build([{:reject, true, false}])
  end

  test "evaluate/2 counts a false link to the wrong referral as cross-referral" do
    r1 = referral()
    r2 = referral(id: "ref_2")
    appt = appointment(id: "appt_x")

    labeled = [
      %{referral: r1, appointment: appt, label: false},
      %{referral: r2, appointment: appt, label: true}
    ]

    report = AppointmentReferralLink.evaluate(labeled)
    assert report.counts == %{{:link, false} => 1, {:link, true} => 1}
    assert report.precision == 0.5
    assert report.cross_referral_false_link_rate == 0.5
  end

  test "evaluate/2 passes options through and raises on invalid config" do
    labeled = [%{referral: referral(), appointment: appointment(), label: true}]
    assert %Report{counts: %{{:review, true} => 1}} = AppointmentReferralLink.evaluate(labeled, link_at: 0.99)
    assert_raise ArgumentError, fn -> AppointmentReferralLink.evaluate(labeled, reject_at: 2.0) end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/appointment_referral_link/evaluate_test.exs`
Expected: FAIL. `Report.build/1 is undefined`.

- [ ] **Step 3: Implement `Report.build/1`**

Add to `lib/appointment_referral_link/report.ex`, inside the module:

```elixir
  @doc """
  Builds the report from `{outcome, label, cross_referral?}` tuples.
  `cross_referral?` is true for a `:link` labeled false whose appointment
  truly belongs to a different referral.
  """
  @spec build([{atom(), boolean(), boolean()}]) :: t()
  def build(results) do
    total = length(results)
    counts = Enum.frequencies_by(results, fn {outcome, label, _} -> {outcome, label} end)
    links = Enum.count(results, &match?({:link, _, _}, &1))
    positives = Enum.count(results, &match?({_, true, _}, &1))
    reviews = Enum.count(results, &match?({:review, _, _}, &1))
    cross = Enum.count(results, &match?({_, _, true}, &1))
    true_links = Map.get(counts, {:link, true}, 0)

    %__MODULE__{
      total: total,
      counts: counts,
      precision: ratio(true_links, links),
      recall: ratio(true_links, positives),
      review_rate: ratio(reviews, total),
      cross_referral_false_link_rate: ratio(cross, links) || 0.0
    }
  end

  defp ratio(_n, 0), do: nil
  defp ratio(n, d), do: n / d
```

- [ ] **Step 4: Implement `evaluate/2`**

Add to `lib/appointment_referral_link.ex`. Extend the alias line to include `Report`:

```elixir
  alias AppointmentReferralLink.{Appointment, Config, Decision, Pipeline, Referral, Report}
```

Then add:

```elixir
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
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `mix test test/appointment_referral_link/evaluate_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/appointment_referral_link.ex lib/appointment_referral_link/report.ex test/appointment_referral_link/evaluate_test.exs
git commit -m "feat: evaluate/2 with precision, recall, review and cross-referral rates"
```

---

### Task 13: Property tests for the safety invariants

**Files:**
- Test: `test/appointment_referral_link/property_test.exs`

**Interfaces:**
- Consumes: `link/3`, `Fixtures`, `Stubs.HighScorer`, `Stubs.HighText`,
  and `PatientMatching.train/2` (as in Task 5)

- [ ] **Step 1: Write the property tests**

```elixir
defmodule AppointmentReferralLink.PropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import AppointmentReferralLink.Fixtures
  alias AppointmentReferralLink.Stubs

  # Worst case: the scorer and the text adapter both claim 0.99, and the
  # text adapter sees every pair.
  @hostile [scorer: Stubs.HighScorer, text_adapter: Stubs.HighText, review_low: 0.0, review_high: 1.0]

  defp decide(r, a, opts \\ @hostile) do
    {:ok, [d]} = AppointmentReferralLink.link(r, [a], opts)
    d
  end

  # Pairs that pass every gate. Window for referral/0 is issued_on-7 .. issued_on+105.
  defp clean_pair do
    gen all offset <- integer(-7..105),
            specialty <- member_of(["orthopedics", "sports_medicine", " Orthopedics"]),
            part <- member_of(["knee", "medial knee", "patella", nil]),
            lat <- member_of([:right, :bilateral, nil]),
            booked <- member_of([true, false, nil]),
            status <- member_of([:booked, :completed]) do
      r = referral()

      a =
        appointment(
          starts_on: Date.add(r.issued_on, offset),
          specialty: specialty,
          body_part: part,
          laterality: lat,
          reason: "knee pain",
          booked_from_referral: booked,
          status: status
        )

      {r, a}
    end
  end

  property "control: clean pairs link under the hostile stubs (properties are not vacuous)" do
    check all {r, a} <- clean_pair() do
      assert decide(r, a).outcome == :link
    end
  end

  property "a laterality conflict never links" do
    check all {r, a} <- clean_pair(),
              {r_lat, r_reason, a_lat, a_reason} <-
                member_of([
                  {:right, "pain", :left, "pain"},
                  {:right, "pain", nil, "lt knee pain"},
                  {:right, "pain", nil, "LEFT knee"},
                  {nil, "right knee", :left, "pain"},
                  {:left, "pain", :right, "pain"}
                ]) do
      d = decide(%{r | laterality: r_lat, reason: r_reason}, %{a | laterality: a_lat, reason: a_reason})
      assert d.outcome == :reject
      assert :laterality_conflict in d.reasons
    end
  end

  property "a failed exact patient gate never links" do
    check all {r, a} <- clean_pair(),
              other <- one_of([constant(nil), string(:alphanumeric, min_length: 1)]),
              other != "p_9" do
      d = decide(r, %{a | patient_id: other})
      assert d.outcome == :reject
      assert d.reasons == [:patient_mismatch]
    end
  end

  property "a pair outside the window never links" do
    check all {r, a} <- clean_pair(),
              offset <- one_of([integer(-400..-8), integer(106..400)]) do
      d = decide(r, %{a | starts_on: Date.add(r.issued_on, offset)})
      assert d.outcome == :reject
      assert :outside_window in d.reasons
    end
  end

  property "excluded statuses never link" do
    check all {r, a} <- clean_pair(), status <- member_of([:cancelled, :no_show]) do
      d = decide(r, %{a | status: status})
      assert d.outcome == :reject
      assert :status_excluded in d.reasons
    end
  end

  property "an appointment linked to another referral never links" do
    check all {r, a} <- clean_pair(),
              other <- string(:alphanumeric, min_length: 1),
              other != r.id do
      d = decide(r, %{a | linked_referral_id: other})
      assert d.outcome == :reject
      assert :already_linked in d.reasons
    end
  end

  describe "Fellegi–Sunter gate" do
    @alice %{given_name: "Alice", family_name: "Example", dob: "1980-01-10", sex: "F",
             zip: "02139", phone: "2125550101", ssn: "212456789"}
    @others [
      %{given_name: "Carol", family_name: "Fiction", dob: "1980-09-15", sex: "F",
        zip: "60601", phone: "3125550103", ssn: "345678901"},
      %{given_name: "Brian", family_name: "Sample", dob: "1980-06-12", sex: "M",
        zip: "10001", phone: "2125550102", ssn: "234567890"}
    ]

    setup_all do
      records =
        [@alice | @others]
        |> Enum.with_index()
        |> Enum.map(fn {p, i} -> Map.put(p, :id, "t#{i}") end)
        |> Kernel.++([
          %{id: "t9", given_name: "Alicx", family_name: "Example", dob: "1980-01-10", sex: "F",
            zip: "02139", phone: "5550101", ssn: "212456789"},
          %{id: "t10", given_name: "Brian", family_name: "Sample", dob: "1980-06-13", sex: "M",
            zip: nil, phone: "2125550102", ssn: "234567890"}
        ])

      %{model: PatientMatching.train(records, PatientMatching.Presets.patient_mpi())}
    end

    property "a failed FS gate never links, even with matching patient_id", %{model: model} do
      opts = @hostile ++ [patient_gate: {:fellegi_sunter, model}]

      check all {r, a} <- clean_pair(), other <- member_of(@others), max_runs: 25 do
        d = decide(%{r | patient: @alice}, %{a | patient: other}, opts)
        assert d.outcome == :reject
        assert d.reasons == [:patient_mismatch]
      end
    end
  end
end
```

- [ ] **Step 2: Run the properties**

Run: `mix test test/appointment_referral_link/property_test.exs`
Expected: PASS. Any failure here is a pipeline bug: fix the pipeline,
never the property.

- [ ] **Step 3: Commit**

```bash
git add test/appointment_referral_link/property_test.exs
git commit -m "test: property tests that gates can never be overridden to link"
```

---

### Task 14: Golden pairs, evaluation gate, and README

**Files:**
- Modify: `test/support/fixtures.ex` (add `load_cases/1`)
- Create: `test/fixtures/golden.json`
- Create: `test/fixtures/baseline.json`
- Test: `test/appointment_referral_link/golden_test.exs`
- Modify: `README.md`

**Interfaces:**
- Consumes: `link/3`, `evaluate/2`
- Produces: `Fixtures.load_cases(Path.t()) :: [%{name, referral, appointment, expected, reasons, label}]`

- [ ] **Step 1: Write the golden fixture**

`test/fixtures/golden.json`. All data is synthetic and de-identified.
Expected outcomes come from the default weights:

| Logit | Probability | Outcome |
|---|---|---|
| 3.1 | 0.957 | link |
| 2.4 | 0.917 | review |
| 2.3 | 0.909 | review |
| 2.1 | 0.891 | review |
| 1.6 | 0.832 | review |
| -2.7 | 0.063 | reject |

```json
{
  "referrals": {
    "R1": {
      "id": "ref_1", "patient_id": "p_9", "issued_on": "2026-09-01", "auth_start": "2026-09-01",
      "auth_end": "2026-12-01", "specialty": "orthopedics",
      "allowed_specialties": ["orthopedics", "sports_medicine"], "body_part": "knee",
      "laterality": "right", "reason": "locking and medial pain", "icd10": ["M23.20"],
      "referring_provider_id": "prv_3", "site_id": "clinic_2"
    },
    "R2": {
      "id": "ref_2", "patient_id": "p_9", "issued_on": "2026-09-10", "auth_start": "2026-09-10",
      "auth_end": "2026-12-10", "specialty": "orthopedics", "allowed_specialties": ["orthopedics"],
      "body_part": "knee", "laterality": "right", "reason": "osteoarthritis follow-up",
      "icd10": ["M17.11"], "referring_provider_id": "prv_4", "site_id": "clinic_2"
    }
  },
  "base_appointment": {
    "patient_id": "p_9", "starts_on": "2026-09-18", "status": "completed",
    "specialty": "orthopedics", "subspecialty": "knee", "body_part": "knee", "laterality": "right",
    "reason": "right knee locking", "cpt": ["99203"], "icd10": ["M23.21"],
    "rendering_provider_id": "prv_8", "site_id": "clinic_2", "booked_from_referral": true,
    "linked_referral_id": null
  },
  "cases": [
    {"name": "clean_link", "referral": "R1", "appointment": {"id": "appt_1"},
     "expected": "link", "reasons": ["score"], "label": true},
    {"name": "bilateral_appointment", "referral": "R1",
     "appointment": {"id": "appt_2", "laterality": "bilateral", "reason": "bilateral knee pain"},
     "expected": "link", "reasons": ["score"], "label": true},
    {"name": "allowed_specialty", "referral": "R1",
     "appointment": {"id": "appt_3", "specialty": "sports_medicine"},
     "expected": "review", "reasons": ["score"], "label": true},
    {"name": "laterality_conflict", "referral": "R1",
     "appointment": {"id": "appt_4", "laterality": "left", "reason": "left knee locking"},
     "expected": "reject", "reasons": ["laterality_conflict"], "label": false},
    {"name": "laterality_conflict_from_text", "referral": "R1",
     "appointment": {"id": "appt_5", "laterality": null, "reason": "lt knee pain"},
     "expected": "reject", "reasons": ["laterality_conflict"], "label": false},
    {"name": "specialty_mismatch", "referral": "R1",
     "appointment": {"id": "appt_6", "specialty": "cardiology"},
     "expected": "reject", "reasons": ["specialty_mismatch"], "label": false},
    {"name": "different_patient", "referral": "R1",
     "appointment": {"id": "appt_7", "patient_id": "p_10"},
     "expected": "reject", "reasons": ["patient_mismatch"], "label": false},
    {"name": "before_window", "referral": "R1",
     "appointment": {"id": "appt_8", "starts_on": "2026-08-20"},
     "expected": "reject", "reasons": ["outside_window"], "label": false},
    {"name": "after_window", "referral": "R1",
     "appointment": {"id": "appt_9", "starts_on": "2026-12-20"},
     "expected": "reject", "reasons": ["outside_window"], "label": false},
    {"name": "lead_edge", "referral": "R1",
     "appointment": {"id": "appt_10", "starts_on": "2026-08-25"},
     "expected": "review", "reasons": ["score"], "label": true},
    {"name": "cancelled", "referral": "R1",
     "appointment": {"id": "appt_11", "status": "cancelled"},
     "expected": "reject", "reasons": ["status_excluded"], "label": false},
    {"name": "linked_elsewhere", "referral": "R1",
     "appointment": {"id": "appt_12", "linked_referral_id": "ref_2"},
     "expected": "reject", "reasons": ["already_linked"], "label": false},
    {"name": "hard_negative_other_referral", "referral": "R1",
     "appointment": {"id": "appt_hn", "starts_on": "2026-09-20", "icd10": ["M17.11"],
                     "reason": "right knee oa follow-up"},
     "expected": "review", "reasons": ["score"], "label": false},
    {"name": "shoulder_visit", "referral": "R1",
     "appointment": {"id": "appt_14", "body_part": "shoulder", "subspecialty": "shoulder",
                     "reason": "right shoulder pain", "icd10": ["M75.100"], "booked_from_referral": false},
     "expected": "reject", "reasons": ["score"], "label": false},
    {"name": "medial_knee_related", "referral": "R1",
     "appointment": {"id": "appt_15", "body_part": "medial knee"},
     "expected": "link", "reasons": ["score"], "label": true},
    {"name": "laterality_unknown", "referral": "R1",
     "appointment": {"id": "appt_16", "laterality": null, "reason": "knee locking"},
     "expected": "review", "reasons": ["score"], "label": true},
    {"name": "hard_negative_true_referral", "referral": "R2",
     "appointment": {"id": "appt_hn", "starts_on": "2026-09-20", "icd10": ["M17.11"],
                     "reason": "right knee oa follow-up"},
     "expected": "link", "reasons": ["score"], "label": true}
  ]
}
```

`test/fixtures/baseline.json`. For reference, on this set recall is 4/7 ≈
0.571 and the review rate is 4/17 ≈ 0.235.

```json
{
  "precision_min": 1.0,
  "cross_referral_false_link_rate_max": 0.0
}
```

- [ ] **Step 2: Add `load_cases/1` to Fixtures**

Add inside `AppointmentReferralLink.Fixtures`:

```elixir
  @date_fields ~w(issued_on auth_start auth_end starts_on)
  @atom_fields ~w(laterality status)

  @doc "Loads golden cases. Test-only: uses String.to_existing_atom on fixture data."
  def load_cases(path) do
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
```

- [ ] **Step 3: Write the golden and evaluation-gate tests**

`test/appointment_referral_link/golden_test.exs`:

```elixir
defmodule AppointmentReferralLink.GoldenTest do
  use ExUnit.Case, async: true

  alias AppointmentReferralLink.Fixtures

  @golden Path.expand("../fixtures/golden.json", __DIR__)
  @baseline Path.expand("../fixtures/baseline.json", __DIR__)

  for c <- Fixtures.load_cases(Path.expand("../fixtures/golden.json", __DIR__)) do
    @case c
    test "golden: #{c.name}" do
      %{referral: r, appointment: a, expected: expected, reasons: reasons} = @case
      {:ok, [d]} = AppointmentReferralLink.link(r, [a])
      assert {d.outcome, d.reasons} == {expected, reasons}, "#{@case.name}: #{inspect(d, pretty: true)}"
    end
  end

  test "evaluation gate: precision and cross-referral false-link rate hold the baseline" do
    baseline = @baseline |> File.read!() |> JSON.decode!()
    labeled = Enum.map(Fixtures.load_cases(@golden), &Map.take(&1, [:referral, :appointment, :label]))
    report = AppointmentReferralLink.evaluate(labeled)

    assert report.precision >= baseline["precision_min"],
           "precision dropped: #{inspect(report)}"

    assert report.cross_referral_false_link_rate <= baseline["cross_referral_false_link_rate_max"],
           "cross-referral false-link rate rose: #{inspect(report)}"
  end
end
```

`load_cases/1` runs at compile time inside the `for`, so the test file
needs `Fixtures` compiled first. `elixirc_paths(:test)` includes
`test/support`, which handles that.

- [ ] **Step 4: Run the tests**

Run: `mix test test/appointment_referral_link/golden_test.exs`
Expected: 18 tests PASS. If a golden case fails, compare
`d.components.score.logit` against the table in Step 1. A mismatch means
a weight or feature bug: fix the code, not the fixture.

- [ ] **Step 5: Replace the README**

`README.md`:

````markdown
# AppointmentReferralLink

Links appointments to referrals. Given one referral and the appointments
already known to be for that patient, each pair gets `:link`, `:reject`,
or `:review`, with structured reasons and a score. Callers persist
decisions; this package does not search a database or store anything.

```elixir
{:ok, decisions} = AppointmentReferralLink.link(referral, appointments)
report = AppointmentReferralLink.evaluate(labeled_pairs)
```

## Pipeline

1. **Patient gate:** exact `patient_id` by default, or
   `patient_gate: {:fellegi_sunter, model}` using a model trained with
   `patient_matching`.
2. **Window gate:** `[issued_on - lead_days, (auth_end || issued_on + default_auth_days) + lag_days]`,
   dropped statuses, and appointments already linked to another referral.
3. **Conflict gate:** a `rule_match` ruleset over pair features
   (`priv/rules/conflicts.json`): laterality conflict, specialty
   mismatch, plus any site rules.
4. **Score:** `Score.Rules` (weighted `rule_match` rules,
   `priv/rules/score_weights.json`) by default, or `Score.Tree` (ONNX via
   the optional `:ortex` dep).
5. **Text residual and threshold:** pairs in the review band go to the
   `text_adapter` (default `Score.Text.None`). A failing adapter sends the
   pair to `:review`. `link_at` and `reject_at` decide the outcome.

Gates only reject. Only the final threshold produces `:link`.

## Configuration

```elixir
config :appointment_referral_link,
  lead_days: 7,
  lag_days: 14,
  link_at: 0.92,
  reject_at: 0.35,
  text_adapter: AppointmentReferralLink.Score.Text.None
```

Every key can be overridden per call. See `AppointmentReferralLink.Config`.
Sites extend the data with `ontology_paths:`, `conflict_rules:` (plus
`conflict_reasons:` for new reason atoms), `score_rules:`, and
`cpt_families:`.

## Tree model

Train outside Elixir on adjudicated pairs, including hard negatives
(same patient, same body part or specialty, nearby date, different
referral). Export with `skl2onnx` (`zipmap: False`) to
`priv/models/linker.onnx`, and put `linker.features.json` next to it to
give the column order. Add `{:ortex, "~> 0.1.10"}` to your app and set
`scorer: AppointmentReferralLink.Score.Tree`.

## Tests

```sh
mix test                    # :ortex tests excluded
mix test --include ortex    # needs test/fixtures/models (scripts/make_test_tree.py)
```
````

- [ ] **Step 6: Run the whole suite and the formatter**

Run: `mix format && mix compile --warnings-as-errors && mix test --include ortex`
Expected: no warnings and every test PASS.

- [ ] **Step 7: Commit**

```bash
git add test/support/fixtures.ex test/fixtures/golden.json test/fixtures/baseline.json test/appointment_referral_link/golden_test.exs README.md
git commit -m "test: golden pairs and evaluation gate; document the package"
```
