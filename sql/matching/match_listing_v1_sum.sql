-- ARCHIVED: original spec-literal matcher (§7.3), kept for rollback/comparison.
-- This is what match_listing.sql looked like before the v2 normalization fix.
--
-- Known issue, confirmed against real data on 2026-07-08: attribute_overlap
-- here is SUM(event_score) across up to 500 of a person's banked events, with
-- no normalization and no hard gate on price. This lets sheer event VOLUME
-- substitute for match PRECISION:
--   - A person whose actual activity (JC Journal Square condos, ~$375K) has
--     nothing to do with a target listing (Hoboken, $1.5M) still topped the
--     ranked results, because hundreds of their events each picked up partial
--     credit for county + property-type match alone (price contributed 0 to
--     every one of them, but that's not a penalty, just a non-contribution).
--   - A person with zero activity in the last 65 days still ranked top-25 on
--     two very different test listings purely on ~1,500 historical events.
-- See match_listing.sql for the normalized (AVG-based) replacement.

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
    SUM(event_score) AS attribute_overlap
  FROM scored
  GROUP BY 1, 2
)
SELECT
  person_id,
  attribute_overlap,
  engagement_intensity,
  attribute_overlap * LN(1 + engagement_intensity) AS match_score
FROM person_scores
WHERE attribute_overlap > 0
ORDER BY match_score DESC
LIMIT @limit;
