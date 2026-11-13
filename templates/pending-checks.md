# Pending checks

Dated things to verify later. `hooks/pending-checks.sh` raises an item on or after its date,
once a day. Each item is at most 5 lines and is deleted (or re-dated) once checked. Results
and history go to the issue tracker, never here.

## Open items

### 2026-12-01 | Nightly export job writes the new column
check: `bq query 'select count(*) from exports.daily where new_col is not null and day = current_date()'`
pass: count > 0 on the first run after the 2026-11-28 deploy
context: https://github.com/example-org/example-repo/pull/123
