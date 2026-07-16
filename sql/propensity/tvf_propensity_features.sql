-- Phase 4, step 2: point-in-time feature table function for the buyer
-- propensity model. A table function (not a plain view) so the SAME feature
-- logic serves both training -- called with the label spine's distinct
-- as_of_dates -- and scoring -- called with [CURRENT_DATE()], see step 5.
-- One row per (person_id, as_of_date). See spec's "Assemble the feature
-- table" step for the candidate feature list.
--
-- Point-in-time correctness (avoiding label leakage):
--   - Events (browsing/inquiries): events_mirror.events_raw_latest is
--     append-only per vw_enriched_events (no changelog columns) -- each row
--     is one immutable event, so filtering occurred_at <= as_of_date is
--     sufficient.
--   - Calls/texts: calls_raw_latest / texts_raw_latest are Firestore
--     change-stream exports (document_id/timestamp/operation/data/old_data),
--     same shape as fub_mirror_ponds.ponds_raw_changelog. duration/isIncoming
--     are set at call-end/send time and don't meaningfully change afterward,
--     so we take each document_id's LATEST known state overall (not
--     re-derived per as_of_date) and filter on occurred_at falling in the
--     window -- avoids an expensive per-as_of_date dedup for fields that are
--     effectively immutable once written.
--   - Emails: same changelog shape, BUT tracking.open.count / tracking.
--     click.count accumulate for days/weeks after send -- using the
--     current/global-latest snapshot for a historical as_of_date would leak
--     future opens/clicks into past training rows. So emails get a real
--     per-as_of_date dedup: for each as_of_date, take each document_id's
--     latest row with mirrored `timestamp` <= as_of_date, and read tracking
--     counts from THAT snapshot, not the globally-latest one.
--   - People (stage/source/created): mirror_people_raw_latest is
--     current-state only, same limitation already accepted for
--     vw_transaction_labels's close_date -- stage/source reflect TODAY's
--     values, not the as-of-date's. Accepted for v1 per the spec's "start
--     simple" guardrail. days_since_created is still as-of-date-correct
--     since `created` itself doesn't change.
--
-- Window cap: 90 days is the widest lookback used below, so every source CTE
-- only keeps rows within 90 days of a spine date, bounding the spine x
-- source join size (46 training dates x ~90-day slice, not the full history).
--
-- Count features default to 0 when a person has no matching activity
-- (COALESCE in the final SELECT); the two recency features
-- (days_since_last_event, days_since_last_two_way_contact) are left NULL for
-- "never happened" rather than a sentinel, since BQML's boosted trees handle
-- NULL as a valid split natively.

CREATE OR REPLACE TABLE FUNCTION `jbg-analytics.propensity.tvf_propensity_features`(target_dates ARRAY<DATE>) AS (
WITH spine_dates AS (
  SELECT DISTINCT d AS as_of_date FROM UNNEST(target_dates) AS d
),

-- Events ----------------------------------------------------------------
events_base AS (
  SELECT
    JSON_VALUE(data, '$.personId')                         AS person_id,
    JSON_VALUE(data, '$.type')                              AS event_type,
    SAFE_CAST(JSON_VALUE(data, '$.occurred') AS TIMESTAMP)  AS occurred_at,
    COALESCE(
      NULLIF(JSON_VALUE(data, '$.property.mlsNumber'), ''),
      JSON_VALUE(data, '$.property.id')
    ) AS listing_key
  FROM `jbg-fub-events-mirror.events_mirror.events_raw_latest`
  WHERE JSON_VALUE(data, '$.property.state') = 'NJ'
    AND COALESCE(JSON_VALUE(data, '$.type'), '') != ''
    AND JSON_VALUE(data, '$.personId') IS NOT NULL
),
events_x_spine AS (
  SELECT sd.as_of_date, e.*
  FROM spine_dates sd
  JOIN events_base e
    ON e.occurred_at <= TIMESTAMP(sd.as_of_date)
   AND e.occurred_at > TIMESTAMP_SUB(TIMESTAMP(sd.as_of_date), INTERVAL 90 DAY)
),
events_features AS (
  SELECT
    as_of_date,
    person_id,
    COUNTIF(occurred_at > TIMESTAMP_SUB(TIMESTAMP(as_of_date), INTERVAL 30 DAY)) AS events_30d,
    COUNTIF(occurred_at > TIMESTAMP_SUB(TIMESTAMP(as_of_date), INTERVAL 60 DAY)) AS events_60d,
    COUNT(*)                                                                     AS events_90d,
    COUNTIF(occurred_at > TIMESTAMP_SUB(TIMESTAMP(as_of_date), INTERVAL 30 DAY)
            AND event_type IN ('Property Inquiry','Seller Inquiry','General Inquiry')) AS inquiries_30d,
    COUNTIF(event_type IN ('Property Inquiry','Seller Inquiry','General Inquiry'))      AS inquiries_90d,
    COUNTIF(occurred_at > TIMESTAMP_SUB(TIMESTAMP(as_of_date), INTERVAL 30 DAY)
            AND event_type IN ('Property Inquiry','Seller Inquiry','General Inquiry',
                                'Virtually Toured Property','Visited Open House',
                                'Phone Call','Text','Felix AI Handoff','Pre-Approval')) AS high_intent_events_30d,
    COUNT(DISTINCT IF(occurred_at > TIMESTAMP_SUB(TIMESTAMP(as_of_date), INTERVAL 30 DAY), listing_key, NULL)) AS distinct_listings_30d,
    COUNT(DISTINCT IF(occurred_at > TIMESTAMP_SUB(TIMESTAMP(as_of_date), INTERVAL 60 DAY), listing_key, NULL)) AS distinct_listings_60d,
    COUNT(DISTINCT listing_key)                                                                                AS distinct_listings_90d,
    -- Trend: 0-30d activity vs. the preceding 31-60d window. No prior-window
    -- activity (a brand-new lead, or one dormant 31-60d ago) reads as NULL
    -- via SAFE_DIVIDE, not a divide-by-zero error.
    SAFE_DIVIDE(
      COUNTIF(occurred_at > TIMESTAMP_SUB(TIMESTAMP(as_of_date), INTERVAL 30 DAY)),
      COUNTIF(occurred_at <= TIMESTAMP_SUB(TIMESTAMP(as_of_date), INTERVAL 30 DAY)
              AND occurred_at > TIMESTAMP_SUB(TIMESTAMP(as_of_date), INTERVAL 60 DAY))
    ) AS trend_30_vs_prior30,
    DATE_DIFF(as_of_date, DATE(MAX(occurred_at)), DAY) AS days_since_last_event
  FROM events_x_spine
  GROUP BY as_of_date, person_id
),

-- Calls -------------------------------------------------------------------
calls_latest AS (
  SELECT
    JSON_VALUE(data, '$.personId')                          AS person_id,
    SAFE_CAST(JSON_VALUE(data, '$.startedAt') AS TIMESTAMP)  AS occurred_at,
    SAFE_CAST(JSON_VALUE(data, '$.isIncoming') AS BOOL)      AS is_incoming,
    SAFE_CAST(JSON_VALUE(data, '$.duration') AS INT64)       AS duration_sec
  FROM (
    SELECT data, ROW_NUMBER() OVER (PARTITION BY document_id ORDER BY timestamp DESC) AS rn
    FROM `jbg-fub-comms-events.comms_events.calls_raw_latest`
  )
  WHERE rn = 1
),
calls_x_spine AS (
  SELECT sd.as_of_date, c.*
  FROM spine_dates sd
  JOIN calls_latest c
    ON c.occurred_at <= TIMESTAMP(sd.as_of_date)
   AND c.occurred_at > TIMESTAMP_SUB(TIMESTAMP(sd.as_of_date), INTERVAL 90 DAY)
  WHERE c.person_id IS NOT NULL
),
calls_features AS (
  SELECT
    as_of_date,
    person_id,
    COUNTIF(is_incoming AND occurred_at > TIMESTAMP_SUB(TIMESTAMP(as_of_date), INTERVAL 30 DAY)) AS calls_incoming_30d,
    COUNTIF(is_incoming)                                                                          AS calls_incoming_90d,
    COUNTIF(NOT is_incoming AND COALESCE(duration_sec, 0) > 0
            AND occurred_at > TIMESTAMP_SUB(TIMESTAMP(as_of_date), INTERVAL 30 DAY))              AS calls_connected_30d,
    COUNTIF(NOT is_incoming AND COALESCE(duration_sec, 0) > 0)                                     AS calls_connected_90d
  FROM calls_x_spine
  GROUP BY as_of_date, person_id
),

-- Texts ---------------------------------------------------------------------
texts_latest AS (
  SELECT
    JSON_VALUE(data, '$.personId')                        AS person_id,
    SAFE_CAST(JSON_VALUE(data, '$.created') AS TIMESTAMP)  AS occurred_at,
    SAFE_CAST(JSON_VALUE(data, '$.isIncoming') AS BOOL)    AS is_incoming
  FROM (
    SELECT data, ROW_NUMBER() OVER (PARTITION BY document_id ORDER BY timestamp DESC) AS rn
    FROM `jbg-fub-comms-events.comms_events.texts_raw_latest`
  )
  WHERE rn = 1
),
texts_x_spine AS (
  SELECT sd.as_of_date, t.*
  FROM spine_dates sd
  JOIN texts_latest t
    ON t.occurred_at <= TIMESTAMP(sd.as_of_date)
   AND t.occurred_at > TIMESTAMP_SUB(TIMESTAMP(sd.as_of_date), INTERVAL 90 DAY)
  WHERE t.person_id IS NOT NULL
),
texts_features AS (
  SELECT
    as_of_date,
    person_id,
    COUNTIF(is_incoming AND occurred_at > TIMESTAMP_SUB(TIMESTAMP(as_of_date), INTERVAL 30 DAY)) AS texts_incoming_30d,
    COUNTIF(is_incoming)                                                                          AS texts_incoming_90d
  FROM texts_x_spine
  GROUP BY as_of_date, person_id
),

-- Emails --------------------------------------------------------------------
-- See header note: tracking counts accumulate post-send, so this dedups
-- PER as_of_date (partition includes as_of_date, not just document_id).
emails_versions AS (
  SELECT
    document_id,
    timestamp                                                          AS mirrored_at,
    SAFE_CAST(JSON_VALUE(data, '$.date') AS TIMESTAMP)                  AS occurred_at,
    SAFE_CAST(JSON_VALUE(data, '$.tracking.open.count') AS INT64)       AS open_count,
    SAFE_CAST(JSON_VALUE(data, '$.tracking.click.count') AS INT64)      AS click_count,
    JSON_QUERY_ARRAY(data, '$.relatedPeople')                          AS related_people
  FROM `jbg-fub-comms-events.comms_events.emails_raw_latest`
),
emails_x_spine AS (
  SELECT * EXCEPT(rn) FROM (
    SELECT
      sd.as_of_date,
      ev.*,
      ROW_NUMBER() OVER (
        PARTITION BY sd.as_of_date, ev.document_id
        ORDER BY ev.mirrored_at DESC
      ) AS rn
    FROM spine_dates sd
    JOIN emails_versions ev
      ON ev.mirrored_at <= TIMESTAMP(sd.as_of_date)
     AND ev.occurred_at > TIMESTAMP_SUB(TIMESTAMP(sd.as_of_date), INTERVAL 90 DAY)
     AND ev.occurred_at <= TIMESTAMP(sd.as_of_date)
  )
  WHERE rn = 1
),
emails_exploded AS (
  SELECT
    ex.as_of_date,
    JSON_VALUE(rp, '$.personId')                       AS person_id,
    SAFE_CAST(JSON_VALUE(rp, '$.sentByPerson') AS BOOL) AS sent_by_person,
    ex.occurred_at,
    ex.open_count,
    ex.click_count
  FROM emails_x_spine ex, UNNEST(ex.related_people) AS rp
),
emails_features AS (
  SELECT
    as_of_date,
    person_id,
    COUNTIF(sent_by_person AND occurred_at > TIMESTAMP_SUB(TIMESTAMP(as_of_date), INTERVAL 30 DAY)) AS emails_from_person_30d,
    COUNTIF(sent_by_person)                                                                          AS emails_from_person_90d,
    COUNTIF(NOT sent_by_person AND COALESCE(open_count, 0) > 0
            AND occurred_at > TIMESTAMP_SUB(TIMESTAMP(as_of_date), INTERVAL 30 DAY))                 AS email_opens_30d,
    COUNTIF(NOT sent_by_person AND COALESCE(open_count, 0) > 0)                                       AS email_opens_90d,
    COUNTIF(NOT sent_by_person AND COALESCE(click_count, 0) > 0
            AND occurred_at > TIMESTAMP_SUB(TIMESTAMP(as_of_date), INTERVAL 30 DAY))                 AS email_clicks_30d,
    COUNTIF(NOT sent_by_person AND COALESCE(click_count, 0) > 0)                                      AS email_clicks_90d
  FROM emails_exploded
  WHERE person_id IS NOT NULL
  GROUP BY as_of_date, person_id
),

-- Combined two-way-contact recency (one feature, across all three channels)
two_way_signals AS (
  SELECT as_of_date, person_id, occurred_at
  FROM calls_x_spine
  WHERE is_incoming OR COALESCE(duration_sec, 0) > 0
  UNION ALL
  SELECT as_of_date, person_id, occurred_at
  FROM texts_x_spine
  WHERE is_incoming
  UNION ALL
  SELECT as_of_date, person_id, occurred_at
  FROM emails_exploded
  WHERE sent_by_person OR COALESCE(open_count, 0) > 0 OR COALESCE(click_count, 0) > 0
),
two_way_recency AS (
  SELECT
    as_of_date,
    person_id,
    DATE_DIFF(as_of_date, DATE(MAX(occurred_at)), DAY) AS days_since_last_two_way_contact
  FROM two_way_signals
  GROUP BY as_of_date, person_id
),

-- People / lead maturity ------------------------------------------------
people_base AS (
  SELECT
    JSON_VALUE(data, '$.id')                             AS person_id,
    SAFE_CAST(JSON_VALUE(data, '$.created') AS TIMESTAMP) AS created_at,
    JSON_VALUE(data, '$.stage')                            AS stage,
    JSON_VALUE(data, '$.source')                           AS source
  FROM `jbg-fub-mirror.fub_mirror_people.mirror_people_raw_latest`
  WHERE JSON_VALUE(data, '$.id') IS NOT NULL
),
-- The full person population x spine dates: left side of every join below,
-- so every live person gets a feature row (zero-filled) even with no
-- events/comms activity -- needed both so the model sees true negatives and
-- so step 5's scoring pass covers the whole current population.
people_x_spine AS (
  SELECT
    sd.as_of_date,
    p.person_id,
    DATE_DIFF(sd.as_of_date, DATE(p.created_at), DAY) AS days_since_created,
    p.stage,
    p.source
  FROM spine_dates sd
  CROSS JOIN people_base p
)

SELECT
  p.as_of_date,
  p.person_id,
  p.days_since_created,
  p.stage,
  p.source,
  COALESCE(ef.events_30d, 0)              AS events_30d,
  COALESCE(ef.events_60d, 0)              AS events_60d,
  COALESCE(ef.events_90d, 0)              AS events_90d,
  COALESCE(ef.inquiries_30d, 0)           AS inquiries_30d,
  COALESCE(ef.inquiries_90d, 0)           AS inquiries_90d,
  COALESCE(ef.high_intent_events_30d, 0)  AS high_intent_events_30d,
  COALESCE(ef.distinct_listings_30d, 0)   AS distinct_listings_30d,
  COALESCE(ef.distinct_listings_60d, 0)   AS distinct_listings_60d,
  COALESCE(ef.distinct_listings_90d, 0)   AS distinct_listings_90d,
  ef.trend_30_vs_prior30,
  ef.days_since_last_event,
  COALESCE(cf.calls_incoming_30d, 0)      AS calls_incoming_30d,
  COALESCE(cf.calls_incoming_90d, 0)      AS calls_incoming_90d,
  COALESCE(cf.calls_connected_30d, 0)     AS calls_connected_30d,
  COALESCE(cf.calls_connected_90d, 0)     AS calls_connected_90d,
  COALESCE(tf.texts_incoming_30d, 0)      AS texts_incoming_30d,
  COALESCE(tf.texts_incoming_90d, 0)      AS texts_incoming_90d,
  COALESCE(mf.emails_from_person_30d, 0)  AS emails_from_person_30d,
  COALESCE(mf.emails_from_person_90d, 0)  AS emails_from_person_90d,
  COALESCE(mf.email_opens_30d, 0)         AS email_opens_30d,
  COALESCE(mf.email_opens_90d, 0)         AS email_opens_90d,
  COALESCE(mf.email_clicks_30d, 0)        AS email_clicks_30d,
  COALESCE(mf.email_clicks_90d, 0)        AS email_clicks_90d,
  twr.days_since_last_two_way_contact
FROM people_x_spine p
LEFT JOIN events_features   ef  ON ef.as_of_date = p.as_of_date AND ef.person_id = p.person_id
LEFT JOIN calls_features    cf  ON cf.as_of_date = p.as_of_date AND cf.person_id = p.person_id
LEFT JOIN texts_features    tf  ON tf.as_of_date = p.as_of_date AND tf.person_id = p.person_id
LEFT JOIN emails_features   mf  ON mf.as_of_date = p.as_of_date AND mf.person_id = p.person_id
LEFT JOIN two_way_recency   twr ON twr.as_of_date = p.as_of_date AND twr.person_id = p.person_id
);
