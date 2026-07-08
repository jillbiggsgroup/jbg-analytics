-- Phase 3: the matcher (v2 — normalized).
-- Given a target listing's attributes, scores every person by
-- (attribute-overlap x engagement-intensity) and returns the top N.
-- See spec §7.
--
-- v2 change from the spec-literal version (preserved at match_listing_v1_sum.sql):
-- attribute_overlap is now AVG(event_score) over only the events that overlap
-- at all with the target (event_score > 0), not SUM(event_score) over all up
-- to 500 banked events. The v1 sum let sheer event volume substitute for
-- match precision -- e.g. a person whose real activity is $375K JC condos
-- still topped the results for a $1.5M Hoboken listing, because hundreds of
-- their events each picked up partial credit for county + property-type
-- match alone, even though price never contributed anything. Averaging over
-- the matching subset means a small number of precisely-matching events beats
-- a large number of loosely-matching ones, while engagement_intensity (via
-- the LN multiplier below) still separately captures how currently active
-- the person is overall.

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
)
SELECT
  person_id,
  attribute_overlap,
  n_matching_events,
  engagement_intensity,
  attribute_overlap * LN(1 + engagement_intensity) AS match_score
FROM person_scores
ORDER BY match_score DESC
LIMIT @limit;
