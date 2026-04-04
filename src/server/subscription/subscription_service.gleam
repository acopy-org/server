import birl
import gleam/dynamic/decode
import pog

pub type Subscription {
  Subscription(
    user_id: String,
    polar_customer_id: String,
    polar_subscription_id: String,
    plan: String,
    status: String,
    current_period_end: String,
    updated_at: String,
  )
}

pub type Plan {
  Free
  Pro
}

pub fn get_plan(db: pog.Connection, user_id: String) -> Plan {
  case get_subscription(db, user_id) {
    Ok(sub) ->
      case sub.plan == "pro" && sub.status == "active" {
        True -> Pro
        False -> Free
      }
    Error(_) -> Free
  }
}

/// Returns the effective plan, accounting for self-hosted mode.
/// When polar_enabled is False (no POLAR_WEBHOOK_SECRET), everyone is Pro.
pub fn get_effective_plan(
  db: pog.Connection,
  user_id: String,
  polar_enabled: Bool,
) -> Plan {
  case polar_enabled {
    False -> Pro
    True -> get_plan(db, user_id)
  }
}

pub fn get_subscription(
  db: pog.Connection,
  user_id: String,
) -> Result(Subscription, Nil) {
  case
    pog.query(
      "SELECT user_id, COALESCE(polar_customer_id, ''), COALESCE(polar_subscription_id, ''), plan, status, COALESCE(current_period_end, ''), updated_at FROM subscriptions WHERE user_id = $1",
    )
    |> pog.parameter(pog.text(user_id))
    |> pog.returning(subscription_decoder())
    |> pog.execute(on: db)
  {
    Ok(pog.Returned(_, [sub, ..])) -> Ok(sub)
    _ -> Error(Nil)
  }
}

pub fn upsert_subscription(
  db: pog.Connection,
  user_id: String,
  polar_customer_id: String,
  polar_subscription_id: String,
  plan: String,
  status: String,
  current_period_end: String,
) -> Result(Nil, pog.QueryError) {
  let now = birl.now() |> birl.to_iso8601
  case
    pog.query(
      "INSERT INTO subscriptions (user_id, polar_customer_id, polar_subscription_id, plan, status, current_period_end, updated_at)
       VALUES ($1, $2, $3, $4, $5, $6, $7)
       ON CONFLICT (user_id) DO UPDATE SET
         polar_customer_id = $2, polar_subscription_id = $3, plan = $4, status = $5, current_period_end = $6, updated_at = $7",
    )
    |> pog.parameter(pog.text(user_id))
    |> pog.parameter(pog.text(polar_customer_id))
    |> pog.parameter(pog.text(polar_subscription_id))
    |> pog.parameter(pog.text(plan))
    |> pog.parameter(pog.text(status))
    |> pog.parameter(pog.text(current_period_end))
    |> pog.parameter(pog.text(now))
    |> pog.execute(on: db)
  {
    Ok(_) -> Ok(Nil)
    Error(e) -> Error(e)
  }
}

pub fn plan_to_string(plan: Plan) -> String {
  case plan {
    Free -> "free"
    Pro -> "pro"
  }
}

pub fn max_devices(plan: Plan) -> Int {
  case plan {
    Free -> 2
    Pro -> 999_999
  }
}

fn subscription_decoder() -> decode.Decoder(Subscription) {
  use user_id <- decode.field(0, decode.string)
  use polar_customer_id <- decode.field(1, decode.string)
  use polar_subscription_id <- decode.field(2, decode.string)
  use plan <- decode.field(3, decode.string)
  use status <- decode.field(4, decode.string)
  use current_period_end <- decode.field(5, decode.string)
  use updated_at <- decode.field(6, decode.string)
  decode.success(Subscription(
    user_id:,
    polar_customer_id:,
    polar_subscription_id:,
    plan:,
    status:,
    current_period_end:,
    updated_at:,
  ))
}
