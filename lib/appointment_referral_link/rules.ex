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
  catch
    # DBConnection exits when the pool dies while the caller waits for a connection.
    :exit, reason -> {:error, {:ruleset, key, Exception.format_exit(reason)}}
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
