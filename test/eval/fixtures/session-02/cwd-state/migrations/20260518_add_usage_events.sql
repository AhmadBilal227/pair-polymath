CREATE TABLE usage_events (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL,
  event_type TEXT NOT NULL,
  quantity INTEGER NOT NULL,
  created_at TEXT NOT NULL
);

-- Backfill will scan all historical request logs and insert usage events.
-- No uniqueness constraint yet on account_id + event_type + created_at.
-- Billing reads this table directly for launch pricing calculations.
