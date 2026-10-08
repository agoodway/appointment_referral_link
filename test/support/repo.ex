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

defmodule AppointmentReferralLink.ExitingRepo do
  @moduledoc false
  # Every query exits before reaching the database, as DBConnection does
  # when the pool dies while a caller waits for a connection.
  use Ecto.Repo, otp_app: :appointment_referral_link, adapter: Ecto.Adapters.Postgres

  @impl true
  def prepare_query(_operation, _query, _opts), do: exit(:pool_gone)
end
