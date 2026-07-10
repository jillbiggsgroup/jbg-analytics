-- Phase 3, §7.4: matcher output joined back to FUB person names.
-- Wraps the v2 normalized matcher (match_listing.sql) and joins person_id to
-- the FUB people mirror so results come back as names, not just IDs.
--
-- Confirmed dataset/table (2026-07-08): jbg-fub-mirror.fub_mirror_people.mirror_people_raw_latest
-- Confirmed field (2026-07-10): p.data.created is an ISO-8601 FUB contact
-- creation timestamp, e.g. "2025-01-19T04:18:31Z".
--
-- New-contact ramp (2026-07-10): a brand-new contact's first events are
-- always undecayed in vw_person_fingerprints, so a burst of high-weight
-- events within their first session (Felix AI Handoff, Property Inquiry,
-- etc.) could outscore a longer-tenured contact whose comparable activity
-- had partially decayed -- confirmed against real data (contacts 0-1 days
-- old jumping thousands of ranks). Unlike a decay-based fix, this uses
-- actual account age (p.data.created), not event history, since a genuinely
-- new contact can rack up several events in one session and any
-- event-count/history-depth gate would miss that. account_age_ramp linearly
-- scales engagement_intensity from 0 to full weight over their first
-- ACCOUNT_AGE_GRACE_DAYS days, then applies no further penalty -- so it only
-- damps the first-session burst, not tenure in general.

-- Parameters (set these before running):
-- @target_price      INT64
-- @target_beds       INT64
-- @target_baths      NUMERIC
-- @target_city       STRING
-- @target_property_type STRING     -- e.g. 'One Family', 'Condo', 'Condominium'
-- @target_county     STRING        -- e.g. 'Hudson'
-- @target_has_parking BOOL
-- @limit             INT64         -- e.g. 25

WITH constants AS (
  SELECT 3.0 AS account_age_grace_days  -- days for a new contact to reach full weight
),
exploded AS (
  SELECT
    fp.person_id,
    fp.engagement_intensity,
    ev.price,
    ev.beds,
    ev.baths,
    ev.city,
    ev.county,
    ev.property_type,
    ev.parking,
    ev.w
  FROM `jbg-analytics.matching.vw_person_fingerprints` fp,
       UNNEST(fp.event_details) ev
  WHERE fp.engagement_intensity > 0
),
scored AS (
  SELECT
    person_id,
    engagement_intensity,
    w * (
      -- Price similarity
      CASE
        WHEN price IS NULL OR @target_price IS NULL THEN 0.0
        WHEN ABS(price - @target_price) / @target_price <= 0.15 THEN 1.0
        WHEN ABS(price - @target_price) / @target_price <= 0.50
          THEN 1.0 - (ABS(price - @target_price) / @target_price - 0.15) / 0.35
        ELSE 0.0
      END
      +
      -- Beds
      CASE
        WHEN beds = @target_beds THEN 1.0
        WHEN ABS(beds - @target_beds) = 1 THEN 0.5
        WHEN ABS(beds - @target_beds) = 2 THEN 0.1
        ELSE 0.0
      END
      +
      -- Baths
      CASE
        WHEN baths = @target_baths THEN 1.0
        WHEN ABS(baths - @target_baths) <= 1.0 THEN 0.5
        ELSE 0.0
      END
      +
      -- City / county
      CASE
        WHEN LOWER(city) = LOWER(@target_city) THEN 1.0
        WHEN LOWER(county) = LOWER(@target_county) THEN 0.4
        ELSE 0.0
      END
      +
      -- Property type
      CASE
        WHEN LOWER(property_type) = LOWER(@target_property_type) THEN 1.0
        WHEN LOWER(property_type) = 'condo (inferred)'
             AND LOWER(@target_property_type) IN ('condo','condominium') THEN 0.9
        ELSE 0.0
      END
      +
      -- Parking feature bonus
      CASE
        WHEN @target_has_parking AND ARRAY_LENGTH(parking) > 0 THEN 0.5
        ELSE 0.0
      END
    ) AS event_score
  FROM exploded
),
person_scores AS (
  SELECT
    person_id,
    engagement_intensity,
    AVG(event_score) AS attribute_overlap,
    COUNT(*) AS n_matching_events
  FROM scored
  WHERE event_score > 0
  GROUP BY 1, 2
),
-- Join to names/stage before ranking so an excluded stage (e.g. Trash) can't
-- occupy one of the top-N slots and shrink the usable result count below @limit.
matches AS (
  SELECT
    ps.person_id,
    ps.attribute_overlap,
    ps.n_matching_events,
    ps.engagement_intensity,
    -- Ramp: 0 at account creation -> 1.0 once account_age_grace_days old.
    -- Missing/unparseable created date fails open (ramp = 1.0) rather than
    -- zeroing out a person's score for a data gap.
    COALESCE(
      LEAST(1.0, GREATEST(
        TIMESTAMP_DIFF(
          CURRENT_TIMESTAMP(),
          SAFE_CAST(JSON_VALUE(p.data, '$.created') AS TIMESTAMP),
          DAY
        ) / c.account_age_grace_days,
        0.0
      )),
      1.0
    ) AS account_age_ramp,
    JSON_VALUE(p.data, '$.firstName')  AS first_name,
    JSON_VALUE(p.data, '$.lastName')   AS last_name,
    JSON_VALUE(p.data, '$.stage')      AS stage,
    JSON_VALUE(p.data, '$.assignedTo') AS assigned_agent
  FROM person_scores ps
  CROSS JOIN constants c
  LEFT JOIN `jbg-fub-mirror.fub_mirror_people.mirror_people_raw_latest` p
    ON JSON_VALUE(p.data, '$.id') = ps.person_id
  WHERE LOWER(COALESCE(JSON_VALUE(p.data, '$.stage'), '')) NOT IN (
    'trash', 'lead', 'attempted contact', 'under contract'
  )
)
SELECT
  attribute_overlap * LN(1 + engagement_intensity * account_age_ramp) AS match_score,
  first_name,
  last_name,
  stage,
  assigned_agent,
  CONCAT('https://jillkbiggs.followupboss.com/2/people/view/', person_id) AS profile_url
FROM matches
ORDER BY match_score DESC
LIMIT @limit;
