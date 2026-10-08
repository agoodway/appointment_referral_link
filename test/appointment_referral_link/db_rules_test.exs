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
