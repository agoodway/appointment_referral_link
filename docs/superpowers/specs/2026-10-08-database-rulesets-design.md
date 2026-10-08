# Database Rulesets Design

## Goal

Let a caller choose, per call, a `rule_match` ruleset stored in PostgreSQL for
the conflict gate and the default scorer, so different sites can run different
rules. The host app maps a site to a ruleset key; this package only loads the
key it is given.

## Decisions

| Question | Decision |
| --- | --- |
| Purpose | Per-site rulesets selected at call time |
| Key selection | Caller names the key on each call: `{:db, key}` |
| Missing ruleset | Returned as `{:error, {:ruleset, key, :not_found}}`, no fallback to defaults, no raise |
| Freshness | No cache; every `link/3` / `evaluate/2` call reads the current rows |
| Repo and prefix | New package config keys `ruleset_repo` and `ruleset_prefix` |

Out of scope: caching, deriving keys from `site_id`, per-ruleset repos,
writing or migrating rulesets (the host uses `RuleMatch.Store` and
`RuleMatch.Migration`), and database sources for the ontology, CPT families,
or tree model.

## Interface

`conflict_rules:` and `score_rules:` accept a fourth source form:

| Source | Meaning |
| --- | --- |
| `nil` | Shipped `priv/rules/*.json` (unchanged) |
| path string | JSON file (unchanged) |
| `%RuleMatch.Ruleset{}` | Used as given (unchanged) |
| `{:db, key}` | Loaded from the database by exact, case-sensitive `key` |

New `Config` keys, settable in `config :appointment_referral_link` and
overridable per call like every other key:

| Key | Default | Meaning |
| --- | --- | --- |
| `ruleset_repo` | `nil` | Host Ecto Repo module used for `{:db, key}` sources |
| `ruleset_prefix` | `"rule_match"` | Schema prefix of the `rule_match` tables |

Example:

```elixir
config :appointment_referral_link, ruleset_repo: MyApp.Repo

AppointmentReferralLink.link(referral, appointments,
  conflict_rules: {:db, "site_42_conflicts"},
  score_rules: {:db, "site_42_score_weights"}
)
```

Either source can be from the database while the other stays a file or the
default.

## Components

**`AppointmentReferralLink.Rules`.** `load/2` becomes `load/3`; the third
argument is a keyword list `[repo: module | nil, prefix: String.t()]` built
from the config. A new clause handles `{:db, key}` by calling:

```elixir
RuleMatch.Ruleset.load(key,
  adapter: RuleMatch.Adapters.Ecto,
  repo: repo,
  prefix: prefix
)
```

It passes the adapter explicitly, so the host's global `:rule_match`
configuration is still never consulted. That keeps the guarantee the module's
comment already states, which the moduledoc comment will now say covers both
sources.

**`Gate.Conflict.load`** and **`Score.Rules.init`** pass the config's repo and
prefix through to `Rules.load/3`. `Score.Rules` keeps its `meta.intercept`
check, so a database ruleset without a numeric intercept fails exactly as a
file does: `{:error, {:score_rules, "meta.intercept must be a number"}}`.

**`Pipeline.prepare/1`** is unchanged apart from the new argument. It already
runs once per `link/3` / `evaluate/2` call, so database loads happen once per
call and one prepared config covers all pairs in that call.

## Validation (`Config.build/1`)

These return `{:error, {:invalid_config, message}}` before any database access:

- `conflict_rules` or `score_rules` is `{:db, key}` and `key` is not a
  non-blank string.
- Either source is `{:db, _}` and `ruleset_repo` is not an atom naming a
  loaded module.
- `ruleset_prefix` is not a non-blank string.
- `conflict_rules` or `score_rules` is any other shape than `nil`, a binary,
  a `%RuleMatch.Ruleset{}`, or `{:db, key}`.

`ruleset_repo` is not checked when no source uses the database, so hosts
without a Repo are unaffected.

## Errors

Every load failure is returned as a value; nothing raises out of `link/3` or
`evaluate/2`. All are wrapped as `{:error, {:ruleset, key, reason}}`, the same
shape file errors use with a path:

| Failure | `reason` |
| --- | --- |
| No row for `key` | `:not_found` |
| Stored definition fails rule_match validation | `{:invalid_ruleset, message}` (as returned by rule_match) |
| Database exception (connection, missing table, wrong prefix) | `Exception.message(e)` |

The rescue for database exceptions matches the containment applied to scorer
and data-file failures in the last two commits.

## Dependencies

No runtime dependencies added; `rule_match` already depends on `ecto_sql`.
`postgrex` is added as `only: :test` for the integration tests. The host supplies
Postgrex, a supervised Repo configured with a JSON types module (per the
rule_match README), and the `RuleMatch.Migration` migration.

## Testing

Unit (default `mix test`):

- `Config.build/1` accepts `{:db, "k"}` with a repo; rejects a blank key, a
  non-string key, a missing repo, a blank prefix, and an unknown source shape.
- `Rules.load/3` with `{:db, key}` against a stub Repo module in
  `test/support/stubs.ex`: a raising Repo yields
  `{:error, {:ruleset, key, message}}`.
- Existing file and struct source tests keep passing.

Integration (tagged `:db`, excluded by default like `:ortex`;
`mix test --include db` with a local Postgres):

- A test Repo in `test/support`, started only when `:db` tests are included,
  with the rule_match migration run under a test prefix.
- A ruleset stored with `RuleMatch.Store` under a site key that adds a
  conflict rule; `link/3` with `conflict_rules: {:db, key}` rejects a pair
  that the shipped rules would not, with the stored rule's id in the decision.
- A stored score ruleset is used by `Score.Rules` (the score matches the
  stored weights and intercept).
- A missing key returns `{:error, {:ruleset, key, :not_found}}`.
- A stored score ruleset without `meta.intercept` returns the
  `:score_rules` error.
- Editing a stored rule between two `link/3` calls changes the second
  result (no caching).

## Documentation

README: add `ruleset_repo` / `ruleset_prefix` to the configuration section, a
short "Database rulesets" section with the example above and a pointer to
rule_match's migration and `RuleMatch.Store`, and the `--include db` test
command.
