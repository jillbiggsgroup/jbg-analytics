-- Phase 3, §7.4: matcher output joined back to FUB person names.
-- Wraps the v2 normalized matcher (match_listing.sql) and joins person_id to
-- the FUB people mirror so results come back as names, not just IDs.
--
-- Confirmed dataset/table (2026-07-08): jbg-fub-mirror.fub_mirror_people.mirror_people_raw_latest

-- Parameters (set these before running):
-- @target_price      INT64
-- @target_beds       INT64
-- @target_baths      NUMERIC
-- @target_city       STRING
-- @target_property_type STRING     -- e.g. 'One Family', 'Condo', 'Condominium'
-- @target_county     STRING        -- e.g. 'Hudson'
-- @target_has_parking BOOL
-- @limit             INT64         -- e.g. 25

WITH exploded AS (
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
    ps.attribute_overlap * LN(1 + ps.engagement_intensity) AS match_score,
    JSON_VALUE(p.data, '$.firstName')  AS first_name,
    JSON_VALUE(p.data, '$.lastName')   AS last_name,
    JSON_VALUE(p.data, '$.stage')      AS stage,
    JSON_VALUE(p.data, '$.assignedTo') AS assigned_agent
  FROM person_scores ps
  LEFT JOIN `jbg-fub-mirror.fub_mirror_people.mirror_people_raw_latest` p
    ON JSON_VALUE(p.data, '$.id') = ps.person_id
  WHERE LOWER(COALESCE(JSON_VALUE(p.data, '$.stage'), '')) != 'trash'
)
SELECT
  person_id,
  first_name,
  last_name,
  stage,
  assigned_agent,
  match_score,
  attribute_overlap,
  n_matching_events,
  engagement_intensity
FROM matches
ORDER BY match_score DESC
LIMIT @limit;
