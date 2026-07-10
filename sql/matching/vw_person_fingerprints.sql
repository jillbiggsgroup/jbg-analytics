-- Phase 2: per-person interest fingerprint.
-- Aggregates each person's recent property-related events with exponential
-- recency decay and event-type weighting into a scalar engagement intensity
-- plus a top-500 array of decayed-weight event details for the matcher to
-- score attribute overlap against. See spec §6.
--
-- Tried and reverted (2026-07-10): dividing engagement_intensity by
-- LN(1 + days since first in-window event) to counter new-contact bias.
-- Confirmed against real data to backfire -- LN(1+d) < 1 for d = 0 or 1, so
-- dividing by it *inflated* same-day/next-day contacts' scores instead of
-- discounting them, and for longer-tenured people it cut their score more
-- than it cut genuinely-new ones, since it scales with days since first
-- observed event rather than actual account age. See match_listing_with_names.sql
-- for the account-age-based approach that replaced it.

CREATE OR REPLACE VIEW `jbg-analytics.matching.vw_person_fingerprints` AS
WITH weighted_events AS (
  SELECT
    e.person_id,
    e.event_type,
    e.intent_class,
    e.occurred_at,
    e.price,
    e.beds,
    e.baths,
    e.city,
    e.county,
    e.property_type,
    e.parking,
    e.building_style,
    -- Event-type weight
    CASE e.event_type
      WHEN 'Felix AI Handoff'          THEN 20.0
      WHEN 'Property Inquiry'          THEN 10.0
      WHEN 'Seller Inquiry'            THEN 10.0
      WHEN 'Pre-Approval'              THEN 10.0
      WHEN 'Virtually Toured Property' THEN  8.0
      WHEN 'Visited Open House'        THEN  8.0
      WHEN 'Phone Call'                THEN  8.0
      WHEN 'General Inquiry'           THEN  5.0
      WHEN 'Text'                      THEN  5.0
      WHEN 'Saved Property'            THEN  3.0
      WHEN 'Shared Property'           THEN  2.0
      WHEN 'Registration'              THEN  2.0
      WHEN 'Viewed Property'           THEN  1.0
      WHEN 'Viewed Page'               THEN  0.3
      WHEN 'Visited Website'           THEN  0.3
      WHEN 'Hid Property'              THEN -2.0
      WHEN 'Unsaved'                   THEN -2.0
      ELSE 0.0
    END AS event_weight,
    -- Recency decay factor
    EXP(
      -LN(2)
      * TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), e.occurred_at, DAY)
      / CASE e.intent_class
          WHEN 'high_intent'   THEN 120.0
          WHEN 'medium_intent' THEN  75.0
          WHEN 'browsing'      THEN  45.0
          WHEN 'negative'      THEN  45.0
          ELSE                       45.0
        END
    ) AS decay
  FROM `jbg-analytics.matching.vw_enriched_events` e
  WHERE e.occurred_at > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 365 DAY)
    AND NOT e.is_rental
    AND e.person_id IS NOT NULL
),
scored AS (
  SELECT
    person_id,
    event_type,
    intent_class,
    price,
    beds,
    baths,
    city,
    county,
    property_type,
    parking,
    building_style,
    event_weight * decay AS w
  FROM weighted_events
)
SELECT
  person_id,
  -- Overall engagement intensity (the anti-dormancy scalar)
  SUM(w)                                                              AS engagement_intensity,
  SUM(IF(intent_class = 'high_intent',   w, 0))                       AS high_intent_score,
  SUM(IF(intent_class = 'medium_intent', w, 0))                       AS medium_intent_score,
  SUM(IF(intent_class = 'browsing',      w, 0))                       AS browsing_score,
  SUM(IF(intent_class = 'negative',      w, 0))                       AS negative_score,
  COUNT(*)                                                            AS event_count,
  MAX(IF(w > 0, DATE(CURRENT_TIMESTAMP()), NULL))                     AS has_positive_activity,
  -- Weighted attribute distributions returned as arrays of struct
  ARRAY_AGG(STRUCT(price, beds, baths, city, county, property_type,
                   parking, building_style, w, event_type)
            ORDER BY w DESC LIMIT 500)                                AS event_details
FROM scored
GROUP BY person_id
HAVING SUM(w) > 0;  -- exclude people with net-zero or net-negative signal
