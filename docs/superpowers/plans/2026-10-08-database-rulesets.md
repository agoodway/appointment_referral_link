# Database Rulesets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let callers pick a PostgreSQL-stored `rule_match` ruleset per call
with `conflict_rules: {:db, key}` / `score_rules: {:db, key}`, so each site can
run its own rules.

**Architecture:**
- `Config` gains `ruleset_repo` and `ruleset_prefix` and validates the four
  ruleset source shapes.
- `Rules.load/3` gains a `{:db, key}` clause that calls
  `RuleMatch.Ruleset.load/2` with the Ecto adapter, repo and prefix all passed
  explicitly, and wraps every failure as `{:error, {:ruleset, key, reason}}`.
- `Gate.Conflict.load/2` and `Score.Rules.init/1` pass the config's repo and
  prefix through. No caching: `Pipeline.prepare/1` already runs once per
  `link/3` / `evaluate/2` call.

**Tech Stack:**
- Elixir 1.19, `rule_match` (its `RuleMatch.Adapters.Ecto`, `RuleMatch.Store`,
  `RuleMatch.Migration`)
- `ecto_sql` (already a transitive dep)
- `postgrex ~> 0.22` (new, test only)

**Spec:** `docs/superpowers/specs/2026-10-08-database-rulesets-design.md`

### Refinements to the spec made while planning (read these first)

1. **`Rules.load/3` never falls back to the global `:rule_match` config.** It
   always passes `repo:` (possibly `nil`) and `prefix:` (defaulting to
   `"rule_match"` when absent from the keyword list) to
   `RuleMatch.Ruleset.load/2`. A `nil` repo therefore comes back as
   `{:error, {:ruleset, key, {:invalid_config, _}}}` from rule_match instead of
   silently using `config :rule_match, repo: ...`.
2. **`Gate.Conflict.load/2`** takes the db options as a second argument with
   default `[]`, so existing `Conflict.load(nil)` calls keep working.
3. **`Rules.db_opts/1`** builds `[repo: c.ruleset_repo, prefix: c.ruleset_prefix]`
   from a `%Config{}`; both call sites use it.
4. **Unit tests use a never-started Repo.** `AppointmentReferralLink.UnstartedRepo`
   is a real `use Ecto.Repo` module that is never started, so any query
   raises `RuntimeError`. This exercises the "database exception" path without
   Postgres.

## Global Constraints

- OTP app `:appointment_referral_link`, root module `AppointmentReferralLink`.
- Elixir `~> 1.19`. Use the built-in `JSON` module; do not add Jason.
- No new runtime deps. Add only `{:postgrex, "~> 0.22", only: :test}`.
- This package never owns a Repo, starts one, or runs migrations outside tests.
- Database loads must pass `adapter: RuleMatch.Adapters.Ecto`, `repo:` and
  `prefix:` explicitly. Never let the host's `:rule_match` app config choose any
  of them.
- No caching of database rulesets.
- Every load failure is a returned value, never a raise, from `link/3`.
  (`evaluate/2` keeps its existing behaviour of raising `ArgumentError` on a
  prepare error.)
- Error shapes, verbatim:
  - missing key → `{:error, {:ruleset, key, :not_found}}`
  - malformed stored definition → `{:error, {:ruleset, key, {:invalid_ruleset, message}}}`
  - database exception → `{:error, {:ruleset, key, Exception.message(e)}}`
  - bad config → `{:error, {:invalid_config, message}}`
- `ruleset_prefix` default is `"rule_match"`. `ruleset_repo` default is `nil`
  and is only required when a source is `{:db, _}`.
- Keys are exact and case-sensitive. Do not trim or downcase them.
- Never create atoms from data. Stored conflict reasons go through the
  existing allow-list in `Gate.Conflict`.

## Review Focus

1. **Database unreachable or Repo not started.** `link/3` must return
   `{:error, {:ruleset, key, message}}`, not crash the caller. Covered in
   Task 2 (`UnstartedRepo`).
2. **Tables not migrated, or wrong `ruleset_prefix`.** Postgrex raises
   `undefined_table`; expect `{:error, {:ruleset, key, message}}`. Covered in
   Task 3.
3. **Key differing only in case** (`"Site_A"` vs `"site_a"`). It must be
   `:not_found`, never a near match. Covered in Task 3.
4. **Host already configures `:rule_match`** (file adapter, other prefix or
   repo). It must not change which database ruleset is loaded. Covered in
   Task 2 (global repo ignored) and Task 3 (global adapter and prefix ignored).
5. **`evaluate/2` with a missing database key.** It must raise
   `ArgumentError` like other prepare errors, not return a report built with
   default rules. Covered in Task 3.

---

## File Structure

| File | Change | Responsibility |
| --- | --- | --- |
| `lib/appointment_referral_link/config.ex` | Modify | New keys; source-shape, key, repo and prefix validation |
| `lib/appointment_referral_link/rules.ex` | Modify | `load/3` with `{:db, key}` clause; `db_opts/1` |
| `lib/appointment_referral_link/gate/conflict.ex` | Modify | `load/2` passes db opts |
| `lib/appointment_referral_link/score/rules.ex` | Modify | `init/1` passes db opts |
| `lib/appointment_referral_link/pipeline.ex` | Modify | Pass db opts to `Gate.Conflict.load/2` |
| `mix.exs` | Modify | `postgrex` test dep |
| `test/support/repo.ex` | Create | `PostgresTypes`, `TestRepo`, `UnstartedRepo`, test migration |
| `test/test_helper.exs` | Modify | Exclude `:db` |
| `test/appointment_referral_link/config_test.exs` | Modify | Config validation tests |
| `test/appointment_referral_link/db_rules_test.exs` | Create | Unit tests, no Postgres |
| `test/appointment_referral_link/db_integration_test.exs` | Create | `:db`-tagged Postgres tests |
| `README.md` | Modify | Config keys, database rulesets section, test command |

---

### Task 1: Config keys and validation

**Files:**
- Modify: `lib/appointment_referral_link/config.ex`
- Test: `test/appointment_referral_link/config_test.exs`

**Interfaces:**
- Consumes: nothing new.
- Produces: `%Config{ruleset_repo: module() | nil, ruleset_prefix: String.t()}`.
  `Config.build/1` accepts `conflict_rules` / `score_rules` values of `nil`, a
  binary, a `%RuleMatch.Ruleset{}`, or `{:db, key}` with a nonblank binary key,
  and returns `{:error, {:invalid_config, msg}}` for anything else.

- [ ] **Step 1: Write the failing tests**

Append this `describe` block inside `AppointmentReferralLink.ConfigTest`, before the module's final `end`:

```elixir
  describe "ruleset sources" do
    test "repo defaults to nil and prefix to rule_match" do
      assert {:ok, c} = Config.build([])
      assert c.ruleset_repo == nil
      assert c.ruleset_prefix == "rule_match"
    end

    test "nil, a path, a struct, and {:db, key} with a repo are accepted" do
      {:ok, ruleset} = RuleMatch.Ruleset.from_json(~s({"format": 1, "rules": []}))

      assert {:ok, _} = Config.build(conflict_rules: nil, score_rules: "w.json")
      assert {:ok, _} = Config.build(conflict_rules: ruleset)

      assert {:ok, c} =
               Config.build(
                 conflict_rules: {:db, "site_a_conflicts"},
                 score_rules: {:db, "site_a_score_weights"},
                 ruleset_repo: Enum,
                 ruleset_prefix: "rules"
               )

      assert c.conflict_rules == {:db, "site_a_conflicts"}
      assert c.ruleset_prefix == "rules"
    end

    test "keys are not trimmed or downcased" do
      assert {:ok, %{conflict_rules: {:db, " Site_A "}}} =
               Config.build(conflict_rules: {:db, " Site_A "}, ruleset_repo: Enum)
    end

    for key <- ["", "   ", :site_a, nil, 42] do
      test "rejects {:db, #{inspect(key)}}" do
        assert {:error, {:invalid_config, msg}} =
                 Config.build(conflict_rules: {:db, unquote(key)}, ruleset_repo: Enum)

        assert msg =~ "conflict_rules"
      end
    end

    for source <- [:file, 42, {:file, "x.json"}, {:db}, {:db, "k", []}] do
      test "rejects source #{inspect(source)}" do
        assert {:error, {:invalid_config, _}} =
                 Config.build(score_rules: unquote(Macro.escape(source)))
      end
    end

    test "a database source requires a loaded repo module" do
      assert {:error, {:invalid_config, msg}} = Config.build(conflict_rules: {:db, "k"})
      assert msg =~ "ruleset_repo"

      assert {:error, {:invalid_config, _}} =
               Config.build(score_rules: {:db, "k"}, ruleset_repo: NoSuchRepo)

      assert {:error, {:invalid_config, _}} =
               Config.build(score_rules: {:db, "k"}, ruleset_repo: "MyApp.Repo")
    end

    test "the repo is not checked when no source uses the database" do
      assert {:ok, _} = Config.build(ruleset_repo: NoSuchRepo)
    end

    test "rejects a blank or non-string prefix" do
      assert {:error, {:invalid_config, msg}} = Config.build(ruleset_prefix: " ")
      assert msg =~ "ruleset_prefix"
      assert {:error, {:invalid_config, _}} = Config.build(ruleset_prefix: :rules)
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/appointment_referral_link/config_test.exs`
Expected: FAIL. The first test fails with `KeyError` / unknown options `[:ruleset_repo, ...]`, and the rejection tests return `{:ok, _}`.

- [ ] **Step 3: Implement**

In `lib/appointment_referral_link/config.ex`, add the two keys to `@defaults` right after `score_rules: nil,`:

```elixir
    score_rules: nil,
    ruleset_repo: nil,
    ruleset_prefix: "rule_match",
```

In `validate/1`, add these clauses immediately before the final `true ->` clause:

```elixir
      not valid_source?(c.conflict_rules) ->
        error(source_message(:conflict_rules))

      not valid_source?(c.score_rules) ->
        error(source_message(:score_rules))

      not (is_binary(c.ruleset_prefix) and String.trim(c.ruleset_prefix) != "") ->
        error("ruleset_prefix must be a nonblank string")

      uses_db?(c) and not loaded_module?(c.ruleset_repo) ->
        error("ruleset_repo must be a loaded Ecto Repo module when a ruleset source is {:db, key}")
```

Add these private helpers after `defp non_neg_int?/1`:

```elixir
  defp valid_source?(nil), do: true
  defp valid_source?(path) when is_binary(path), do: true
  defp valid_source?(%RuleMatch.Ruleset{}), do: true
  defp valid_source?({:db, key}) when is_binary(key), do: String.trim(key) != ""
  defp valid_source?(_), do: false

  defp source_message(key),
    do: "#{key} must be nil, a file path, a %RuleMatch.Ruleset{}, or {:db, key} with a nonblank string key"

  defp uses_db?(c), do: Enum.any?([c.conflict_rules, c.score_rules], &match?({:db, _}, &1))

  defp loaded_module?(m), do: is_atom(m) and not is_nil(m) and Code.ensure_loaded?(m)
```

Update the moduledoc's first paragraph to mention the new keys by appending
this sentence: "`ruleset_repo` and `ruleset_prefix` locate `{:db, key}`
ruleset sources."

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/appointment_referral_link/config_test.exs`
Expected: PASS.

Run: `mix test`
Expected: PASS (all existing tests still green).

- [ ] **Step 5: Commit**

```bash
git add lib/appointment_referral_link/config.ex test/appointment_referral_link/config_test.exs
git commit -m "feat: ruleset_repo and ruleset_prefix config with {:db, key} sources"
```

---

### Task 2: Load `{:db, key}` rulesets

**Files:**
- Modify: `mix.exs`
- Create: `test/support/repo.ex`
- Modify: `lib/appointment_referral_link/rules.ex`
- Modify: `lib/appointment_referral_link/gate/conflict.ex`
- Modify: `lib/appointment_referral_link/score/rules.ex`
- Modify: `lib/appointment_referral_link/pipeline.ex:24-27`
- Test: `test/appointment_referral_link/db_rules_test.exs`

**Interfaces:**
- Consumes: Task 1's `%Config{ruleset_repo:, ruleset_prefix:}` and validated `{:db, key}` sources.
- Produces:
  - `Rules.load(source, default :: Path.t(), db_opts :: keyword()) :: {:ok, RuleMatch.Ruleset.t()} | {:error, {:ruleset, Path.t() | String.t(), term()}}`, with `db_opts` defaulting to `[]`.
  - `Rules.db_opts(Config.t()) :: [repo: module() | nil, prefix: String.t()]`
  - `Gate.Conflict.load(source, db_opts \\ [])`
  - Test modules `AppointmentReferralLink.PostgresTypes`, `AppointmentReferralLink.TestRepo` and `AppointmentReferralLink.UnstartedRepo` (both `use Ecto.Repo, otp_app: :appointment_referral_link, adapter: Ecto.Adapters.Postgres`), and `AppointmentReferralLink.TestRepo.AddRuleMatch` (an `Ecto.Migration` running `RuleMatch.Migration` under prefix `"arl_test"`). Task 3 uses these.

- [ ] **Step 1: Add the test dependency and the test Repo modules**

In `mix.exs`, add to `deps/0` after the `stream_data` line:

```elixir
      {:stream_data, "~> 1.1", only: :test},
      {:postgrex, "~> 0.22", only: :test}
```

Create `test/support/repo.ex`:

```elixir
# JSONB fields decode with the built-in JSON module, as rule_match requires.
Postgrex.Types.define(AppointmentReferralLink.PostgresTypes, [], json: JSON)

defmodule AppointmentReferralLink.TestRepo do
  @moduledoc false
  # Started only by :db-tagged tests.
  use Ecto.Repo, otp_app: :appointment_referral_link, adapter: Ecto.Adapters.Postgres
end

defmodule AppointmentReferralLink.UnstartedRepo do
  @moduledoc false
  # Never started: every query raises, standing in for an unreachable database.
  use Ecto.Repo, otp_app: :appointment_referral_link, adapter: Ecto.Adapters.Postgres
end

defmodule AppointmentReferralLink.TestRepo.AddRuleMatch do
  @moduledoc false
  use Ecto.Migration

  def up, do: RuleMatch.Migration.up(prefix: "arl_test")
  def down, do: RuleMatch.Migration.down(prefix: "arl_test")
end
```

Run: `mix deps.get && mix compile`
Expected: postgrex is fetched; compiles with no warnings.

- [ ] **Step 2: Write the failing tests**

Create `test/appointment_referral_link/db_rules_test.exs`:

```elixir
defmodule AppointmentReferralLink.DbRulesTest do
  # async: false because one test sets :rule_match application env.
  use ExUnit.Case, async: false

  import AppointmentReferralLink.Fixtures
  alias AppointmentReferralLink.{Gate, Rules, UnstartedRepo}

  @unstarted [ruleset_repo: UnstartedRepo]

  describe "a database that cannot be reached is an error, not a crash" do
    for key <- [:conflict_rules, :score_rules] do
      test "#{key}" do
        opts = [{unquote(key), {:db, "site_a"}} | @unstarted]

        assert {:error, {:ruleset, "site_a", msg}} =
                 AppointmentReferralLink.link(referral(), [appointment()], opts)

        assert is_binary(msg)
        assert msg =~ "UnstartedRepo"
      end
    end
  end

  test "a module that is not a Repo is rule_match's invalid_config, wrapped" do
    assert {:error, {:ruleset, "site_a", {:invalid_config, _}}} =
             AppointmentReferralLink.link(referral(), [appointment()],
               conflict_rules: {:db, "site_a"},
               ruleset_repo: Enum
             )
  end

  test "evaluate/2 raises on an unreachable database, like other prepare errors" do
    assert_raise ArgumentError, ~r/site_a/, fn ->
      AppointmentReferralLink.evaluate([], [conflict_rules: {:db, "site_a"}] ++ @unstarted)
    end
  end

  test "the host's :rule_match repo is never used" do
    Application.put_env(:rule_match, :repo, UnstartedRepo)
    on_exit(fn -> Application.delete_env(:rule_match, :repo) end)

    # With no repo in db_opts, rule_match must see repo: nil, not the global one.
    assert {:error, {:ruleset, "k", {:invalid_config, msg}}} =
             Rules.load({:db, "k"}, Gate.Conflict.default_path(), [])

    assert msg =~ "repo"
  end

  test "db_opts reads the config" do
    {:ok, c} = AppointmentReferralLink.Config.build(ruleset_repo: Enum, ruleset_prefix: "p")
    assert Rules.db_opts(c) == [repo: Enum, prefix: "p"]
  end

  test "file and struct sources ignore db_opts" do
    assert {:ok, %RuleMatch.Ruleset{}} = Gate.Conflict.load(nil, repo: UnstartedRepo)
    assert {:ok, %RuleMatch.Ruleset{}} = Gate.Conflict.load(Gate.Conflict.default_path())
  end
end
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `mix test test/appointment_referral_link/db_rules_test.exs`
Expected: FAIL. `Rules.db_opts/1` and `Gate.Conflict.load/2` are undefined, and `link/3` treats `{:db, _}` as unhandled (a `FunctionClauseError` in `Rules.load/2`).

- [ ] **Step 4: Implement `Rules`**

Replace the body of `lib/appointment_referral_link/rules.ex` with:

```elixir
defmodule AppointmentReferralLink.Rules do
  @moduledoc false
  # Loads rule_match rulesets from JSON files or, for `{:db, key}`, through
  # rule_match's Ecto adapter with the repo and prefix passed explicitly. The
  # host's `:rule_match` configuration (adapter, repo, prefix) is never consulted.

  alias AppointmentReferralLink.Config

  @type source :: nil | Path.t() | RuleMatch.Ruleset.t() | {:db, String.t()}

  @spec load(source(), Path.t(), keyword()) ::
          {:ok, RuleMatch.Ruleset.t()} | {:error, {:ruleset, Path.t() | String.t(), term()}}
  def load(source, default, db_opts \\ [])

  def load(nil, default, db_opts), do: load(default, default, db_opts)
  def load(%RuleMatch.Ruleset{} = ruleset, _default, _db_opts), do: {:ok, ruleset}

  def load({:db, key}, _default, db_opts) do
    opts = [
      adapter: RuleMatch.Adapters.Ecto,
      repo: Keyword.get(db_opts, :repo),
      prefix: Keyword.get(db_opts, :prefix, "rule_match")
    ]

    case RuleMatch.Ruleset.load(key, opts) do
      {:ok, ruleset} -> {:ok, ruleset}
      {:error, reason} -> {:error, {:ruleset, key, reason}}
    end
  rescue
    # Database exceptions (repo not started, connection refused, missing table).
    e -> {:error, {:ruleset, key, Exception.message(e)}}
  end

  def load(path, _default, _db_opts) when is_binary(path) do
    with {:ok, json} <- File.read(path),
         {:ok, ruleset} <- RuleMatch.Ruleset.from_json(json) do
      {:ok, ruleset}
    else
      {:error, reason} -> {:error, {:ruleset, path, reason}}
    end
  rescue
    # rule_match raises on valid JSON of the wrong shape (e.g. "rules": "x").
    e -> {:error, {:ruleset, path, Exception.message(e)}}
  end

  @spec db_opts(Config.t()) :: keyword()
  def db_opts(%Config{ruleset_repo: repo, ruleset_prefix: prefix}),
    do: [repo: repo, prefix: prefix]

  @spec priv(Path.t()) :: Path.t()
  def priv(relative), do: Application.app_dir(:appointment_referral_link, relative)
end
```

- [ ] **Step 5: Wire the call sites**

In `lib/appointment_referral_link/gate/conflict.ex`, replace the `load/1` spec and function with:

```elixir
  @spec load(Rules.source(), keyword()) :: {:ok, RuleMatch.Ruleset.t()} | {:error, term()}
  def load(source, db_opts \\ []), do: Rules.load(source, default_path(), db_opts)
```

In `lib/appointment_referral_link/score/rules.ex`, replace the head and first line of `init/1`:

```elixir
  def init(%Config{score_rules: source} = c) do
    with {:ok, ruleset} <- Rules.load(source, default_path(), Rules.db_opts(c)) do
```

Also change its moduledoc's last sentence from "Swap the file with `:score_rules`." to "Swap the ruleset with `:score_rules` (a path, a struct, or `{:db, key}`)."

In `lib/appointment_referral_link/pipeline.ex`, add `Rules` to the alias list (alphabetically, after `Referral`) and change line 26:

```elixir
         {:ok, conflicts} <- Gate.Conflict.load(c.conflict_rules, Rules.db_opts(c)),
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `mix test test/appointment_referral_link/db_rules_test.exs`
Expected: PASS.

Run: `mix test`
Expected: PASS. `mix compile --warnings-as-errors` is also clean.

- [ ] **Step 7: Commit**

```bash
git add mix.exs mix.lock test/support/repo.ex lib/appointment_referral_link/rules.ex \
  lib/appointment_referral_link/gate/conflict.ex lib/appointment_referral_link/score/rules.ex \
  lib/appointment_referral_link/pipeline.ex test/appointment_referral_link/db_rules_test.exs
git commit -m "feat: load conflict and score rulesets from the database with {:db, key}"
```

---

### Task 3: Postgres integration tests and README

**Files:**
- Modify: `test/test_helper.exs`
- Create: `test/appointment_referral_link/db_integration_test.exs`
- Modify: `README.md`

**Interfaces:**
- Consumes: from Task 2, `AppointmentReferralLink.TestRepo`, `AppointmentReferralLink.PostgresTypes`, `AppointmentReferralLink.TestRepo.AddRuleMatch` (prefix `"arl_test"`), and `{:db, key}` loading through `link/3` / `evaluate/2`.
- Produces: `mix test --include db` coverage; README docs.

The tests need a local Postgres. The URL comes from `ARL_TEST_DATABASE_URL`, defaulting to
`postgres://postgres:postgres@localhost/appointment_referral_link_test`
(verified to work on this machine as role `postgres`). The test creates the
database if it is missing.

- [ ] **Step 1: Exclude `:db` by default**

Change `test/test_helper.exs` to:

```elixir
ExUnit.start(exclude: [:ortex, :db])
```

- [ ] **Step 2: Write the integration tests**

Create `test/appointment_referral_link/db_integration_test.exs`:

```elixir
defmodule AppointmentReferralLink.DbIntegrationTest do
  use ExUnit.Case, async: false

  import AppointmentReferralLink.Fixtures
  alias AppointmentReferralLink.{PostgresTypes, Score, TestRepo}
  alias RuleMatch.Store

  @moduletag :db

  @prefix "arl_test"
  @store [repo: TestRepo, prefix: @prefix]
  @db [ruleset_repo: TestRepo, ruleset_prefix: @prefix]

  setup_all do
    url =
      System.get_env(
        "ARL_TEST_DATABASE_URL",
        "postgres://postgres:postgres@localhost/appointment_referral_link_test"
      )

    # storage_up/1 needs :database etc., not a URL.
    storage = Ecto.Repo.Supervisor.parse_url(url)
    assert Ecto.Adapters.Postgres.storage_up(storage) in [:ok, {:error, :already_up}]

    start_supervised!({TestRepo, url: url, types: PostgresTypes, pool_size: 2, log: false})

    Ecto.Migrator.run(TestRepo, [{20_261_008_000_000, TestRepo.AddRuleMatch}], :up,
      all: true,
      log: false
    )

    TestRepo.query!("TRUNCATE #{@prefix}.rulesets CASCADE")
    :ok
  end

  # Rejects the otherwise-linking fixture pair: laterality agrees for it.
  @block_agree %{
    rule_id: "block_agree",
    priority: 10,
    conditions: [%{"op" => "eq", "field" => "laterality_match", "value" => "agree"}],
    outcome: %{"reason" => "site_rule"}
  }

  defp store!(key, attrs \\ %{}, rules \\ []) do
    {:ok, _} = Store.create_ruleset(Map.merge(%{key: key, name: key, version: "1"}, attrs), @store)
    for rule <- rules, do: {:ok, _} = Store.create_rule(key, rule, @store)
    key
  end

  defp link(opts), do: AppointmentReferralLink.link(referral(), [appointment()], opts ++ @db)

  test "the fixture pair links under the shipped rules" do
    assert {:ok, [%{outcome: :link}]} = link([])
  end

  test "a stored conflict rule rejects the pair, with its id in the trace" do
    key = store!("site_a_conflicts", %{}, [@block_agree])

    assert {:ok, [d]} = link(conflict_rules: {:db, key})
    assert d.outcome == :reject
    # "site_rule" is not an allowed reason atom, so it maps to :conflict_rule.
    assert d.reasons == [:conflict_rule]
    assert d.components.conflict_rules == ["block_agree"]
  end

  test "a stored score ruleset is used with its intercept and weights" do
    key = store!("site_a_scores", %{meta: %{"intercept" => 5.0}})

    assert {:ok, [d]} = link(score_rules: {:db, key})
    assert_in_delta d.score, Score.Rules.logistic(5.0), 1.0e-9
    assert d.components.score.rules == []
  end

  test "a missing key is :not_found" do
    assert {:error, {:ruleset, "absent", :not_found}} = link(conflict_rules: {:db, "absent"})
    assert {:error, {:ruleset, "absent", :not_found}} = link(score_rules: {:db, "absent"})
  end

  test "keys are exact and case-sensitive" do
    store!("site_b_conflicts", %{}, [@block_agree])

    assert {:error, {:ruleset, "Site_B_conflicts", :not_found}} =
             link(conflict_rules: {:db, "Site_B_conflicts"})
  end

  test "a stored score ruleset without an intercept is a score_rules error" do
    key = store!("site_c_scores")

    assert {:error, {:score_rules, "meta.intercept must be a number"}} =
             link(score_rules: {:db, key})
  end

  test "an unmigrated prefix is an error tuple, not a crash" do
    assert {:error, {:ruleset, "site_a_conflicts", msg}} =
             AppointmentReferralLink.link(referral(), [appointment()],
               conflict_rules: {:db, "site_a_conflicts"},
               ruleset_repo: TestRepo,
               ruleset_prefix: "arl_missing"
             )

    assert is_binary(msg)
  end

  test "edits take effect on the next call (no cache)" do
    key = store!("site_d_conflicts", %{}, [@block_agree])
    assert {:ok, [%{outcome: :reject}]} = link(conflict_rules: {:db, key})

    never = [%{"op" => "eq", "field" => "laterality_match", "value" => "conflict"}]
    {:ok, _} = Store.update_rule(key, "block_agree", %{conditions: never}, @store)

    assert {:ok, [%{outcome: :link}]} = link(conflict_rules: {:db, key})
  end

  test "the host's :rule_match adapter and prefix are ignored" do
    key = store!("site_e_conflicts", %{}, [@block_agree])
    Application.put_env(:rule_match, :adapter, RuleMatch.Adapters.File)
    Application.put_env(:rule_match, :prefix, "arl_missing")

    on_exit(fn ->
      Application.delete_env(:rule_match, :adapter)
      Application.delete_env(:rule_match, :prefix)
    end)

    assert {:ok, [%{outcome: :reject}]} = link(conflict_rules: {:db, key})
  end

  test "evaluate/2 raises on a missing key" do
    assert_raise ArgumentError, ~r/not_found/, fn ->
      AppointmentReferralLink.evaluate([], [conflict_rules: {:db, "absent"}] ++ @db)
    end
  end
end
```

- [ ] **Step 3: Run the integration tests**

Run: `mix test --include db test/appointment_referral_link/db_integration_test.exs`
Expected: PASS (10 tests). If `setup_all` fails to connect, set
`ARL_TEST_DATABASE_URL` to a reachable server and rerun. Do not change the
assertions.

Then rerun the same command a second time.
Expected: PASS again. This confirms the migration is idempotent and the
truncate gives a clean slate.

Run: `mix test`
Expected: PASS, with the `:db` tests excluded.

- [ ] **Step 4: Update the README**

In `README.md`, in the "Configuration" section, after the sentence ending `` and `cpt_families:`. ``, add:

````markdown

## Database rulesets

`conflict_rules:` and `score_rules:` also accept `{:db, key}`, loading a
ruleset stored with rule_match's PostgreSQL tables. The host owns the Repo,
runs `RuleMatch.Migration` in its own migration, and writes rulesets with
`RuleMatch.Store`. Point this package at the Repo once, then pick a key per
call (for example, per site):

```elixir
config :appointment_referral_link, ruleset_repo: MyApp.Repo   # ruleset_prefix: "rule_match"

AppointmentReferralLink.link(referral, appointments,
  conflict_rules: {:db, "site_42_conflicts"},
  score_rules: {:db, "site_42_score_weights"}
)
```

Keys are exact and case-sensitive. Rows are read on every call (no cache).
Failures are returned, never raised: a missing key is
`{:error, {:ruleset, key, :not_found}}`; there is no fallback to the shipped
rules. A stored score ruleset needs `meta.intercept`. The host's
`config :rule_match` settings are not used.
````

In the "Tests" section's code block, add a line:

```sh
mix test --include db       # needs Postgres; ARL_TEST_DATABASE_URL overrides the default URL
```

- [ ] **Step 5: Commit**

```bash
git add test/test_helper.exs test/appointment_referral_link/db_integration_test.exs README.md
git commit -m "test: Postgres integration tests for database rulesets; document them"
```

Note: `README.md` already has uncommitted edits from before this plan. Stage
only the database-rulesets hunks (`git add -p README.md`), or ask the user how
they want those earlier edits handled before committing.
