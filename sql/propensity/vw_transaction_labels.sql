-- Phase 4, step 1: point-in-time training label for the buyer propensity model.
-- One row per (person, as_of_date), label = 1 if the person's transaction
-- close falls within (as_of_date, as_of_date + 60 days], else 0. See spec:
-- "Buyer Propensity-to-Act Score", step 1.
--
-- Label field (2026-07-15): p.data.customCloseDate on
-- jbg-fub-mirror.fub_mirror_people.mirror_people_raw_latest. Confirmed
-- against real data: 2,558 of 197,480 people have a close date, distributed
-- as a smooth organic YoY growth curve from 1999 through 2026 (1, 2, 2, 7,
-- 6, 7, 18, 30, 24, 30, 52, 74, 88, 209, 343, 262, 444, 604, 355-partial) --
-- not a backfill dump, so no special-case cutoff year is needed for the
-- label field itself.
--
-- as_of_date window (2026-07-15): bounded by the LATER of the two feature
-- sources' start dates, not the label's own history --
--   - events_mirror.events_raw_latest.occurred: 2024-12-19 to present
--   - comms_events (calls/emails/texts)_raw_latest: 2025-07-01 to present
-- Using as-of-dates before comms coverage began would make every comms
-- feature a hard zero for those rows -- not "no engagement," but "no comms
-- pipeline yet" -- which the model would learn as a spurious date signal
-- rather than real behavior. So the spine starts 2025-07-01. The upper bound
-- is CURRENT_DATE() - 60 days, so every as_of_date's label window has fully
-- elapsed (no censored/partial windows).
--
-- Known limitation: mirror_people_raw_latest is current-state, not a
-- changelog, so customCloseDate only holds a person's MOST RECENT close.
-- Someone with multiple historical closings only labels their latest one --
-- accepted for a first pass per the spec's "start simple" guardrail.
--
-- Weekly cadence keeps the spine x person cross join (~197k people x ~46
-- weeks) tractable; revisit if training_features (Phase 4, step 2) proves
-- too large or too sparse once built.

CREATE OR REPLACE VIEW `jbg-analytics.propensity.vw_transaction_labels` AS
WITH spine AS (
  SELECT as_of_date
  FROM UNNEST(GENERATE_DATE_ARRAY(
    DATE('2025-07-01'),
    DATE_SUB(CURRENT_DATE(), INTERVAL 60 DAY),
    INTERVAL 7 DAY
  )) AS as_of_date
),
people AS (
  SELECT
    JSON_VALUE(data, '$.id') AS person_id,
    SAFE_CAST(JSON_VALUE(data, '$.customCloseDate') AS DATE) AS close_date
  FROM `jbg-fub-mirror.fub_mirror_people.mirror_people_raw_latest`
  WHERE JSON_VALUE(data, '$.id') IS NOT NULL
)
SELECT
  p.person_id,
  s.as_of_date,
  p.close_date,
  IF(
    p.close_date IS NOT NULL
    AND p.close_date > s.as_of_date
    AND p.close_date <= DATE_ADD(s.as_of_date, INTERVAL 60 DAY),
    1, 0
  ) AS label
FROM people p
CROSS JOIN spine s;
