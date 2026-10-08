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
    {:ok, _} =
      Store.create_ruleset(Map.merge(%{key: key, name: key, version: "1"}, attrs), @store)

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
