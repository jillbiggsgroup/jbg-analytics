-- Phase 4, step 7 (evidence for Dan): side-by-side comparison of the live
-- matcher's ranking (match_listing_with_names.sql) against the propensity-
-- boosted ranking (match_listing_with_propensity.sql), computed from the
-- SAME underlying `matches` CTE so it's a true apples-to-apples diff, not
-- two separate queries whose person sets could drift.
--
-- Gate is intentionally left off here (propensity_threshold unused) --
-- this run is about showing the RE-RANKING effect alone, isolated from any
-- filtering decision, since the threshold is exactly what needs Dan's
-- sign-off. Run this first, bring the rank_change results to that
-- conversation, then decide on a threshold separately.
--
-- rank_change = baseline_rank - boosted_rank: positive means propensity
-- moved that person UP the rankings (toward #1), negative means down.
-- WHERE clause below keeps anyone who placed in the top @limit under
-- EITHER ranking, so you can see both who's newly promoted into the
-- results and who dropped out, not just movement among survivors.

-- Parameters (same as match_listing_with_names.sql):
-- @target_price      INT64
-- @target_beds       INT64
-- @target_baths      NUMERIC
-- @target_city       STRING
-- @target_property_type STRING     -- e.g. 'One Family', 'Condo', 'Condominium'
-- @target_county     STRING        -- e.g. 'Hudson'
-- @target_has_parking BOOL
-- @limit             INT64         -- e.g. 25

WITH constants AS (
  SELECT
    3.0 AS account_age_grace_days,
    14.0 AS comms_half_life_days,
    0.5 AS comms_boost_weight,
    1.0 AS propensity_weight
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
      CASE
        WHEN price IS NULL OR @target_price IS NULL THEN 0.0
        WHEN ABS(price - @target_price) / @target_price <= 0.15 THEN 1.0
        WHEN ABS(price - @target_price) / @target_price <= 0.50
          THEN 1.0 - (ABS(price - @target_price) / @target_price - 0.15) / 0.35
        ELSE 0.0
      END
      +
      CASE
        WHEN beds = @target_beds THEN 1.0
        WHEN ABS(beds - @target_beds) = 1 THEN 0.5
        WHEN ABS(beds - @target_beds) = 2 THEN 0.1
        ELSE 0.0
      END
      +
      CASE
        WHEN baths = @target_baths THEN 1.0
        WHEN ABS(baths - @target_baths) <= 1.0 THEN 0.5
        ELSE 0.0
      END
      +
      CASE
        WHEN LOWER(city) = LOWER(@target_city) THEN 1.0
        WHEN LOWER(county) = LOWER(@target_county) THEN 0.4
        ELSE 0.0
      END
      +
      CASE
        WHEN LOWER(property_type) = LOWER(@target_property_type) THEN 1.0
        WHEN LOWER(property_type) = 'condo (inferred)'
             AND LOWER(@target_property_type) IN ('condo','condominium') THEN 0.9
        ELSE 0.0
      END
      +
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
latest_ponds AS (
  SELECT
    document_id,
    COALESCE(JSON_VALUE(data, '$.name'), JSON_VALUE(old_data, '$.name')) AS pond_name
  FROM (
    SELECT
      document_id,
      data,
      old_data,
      ROW_NUMBER() OVER (PARTITION BY document_id ORDER BY timestamp DESC) AS rn
    FROM `jbg-fub-mirror.fub_mirror_ponds.ponds_raw_changelog`
  )
  WHERE rn = 1
),
matches AS (
  SELECT
    ps.person_id,
    ps.attribute_overlap,
    ps.engagement_intensity,
    sc.propensity_score,
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
    1 + c.comms_boost_weight * EXP(
      -LN(2)
      * TIMESTAMP_DIFF(
          CURRENT_TIMESTAMP(),
          GREATEST(
            COALESCE(SAFE_CAST(JSON_VALUE(p.data, '$.lastReceivedEmail')           AS TIMESTAMP), TIMESTAMP('1970-01-01')),
            COALESCE(SAFE_CAST(JSON_VALUE(p.data, '$.lastReceivedText')            AS TIMESTAMP), TIMESTAMP('1970-01-01')),
            COALESCE(SAFE_CAST(JSON_VALUE(p.data, '$.lastReceivedInboxAppMessage') AS TIMESTAMP), TIMESTAMP('1970-01-01'))
          ),
          DAY
        )
      / c.comms_half_life_days
    ) AS comms_boost,
    1 + c.propensity_weight * COALESCE(sc.propensity_score, 0) AS propensity_boost,
    JSON_VALUE(p.data, '$.firstName')  AS first_name,
    JSON_VALUE(p.data, '$.lastName')   AS last_name,
    JSON_VALUE(p.data, '$.stage')      AS stage,
    JSON_VALUE(p.data, '$.assignedTo') AS assigned_agent,
    pond.pond_name                     AS pond_name
  FROM person_scores ps
  CROSS JOIN constants c
  LEFT JOIN `jbg-fub-mirror.fub_mirror_people.mirror_people_raw_latest` p
    ON JSON_VALUE(p.data, '$.id') = ps.person_id
  LEFT JOIN latest_ponds pond
    ON pond.document_id = JSON_VALUE(p.data, '$.assignedPondId')
  LEFT JOIN `jbg-analytics.propensity.scores_buyer_propensity` sc
    ON sc.person_id = ps.person_id
  WHERE LOWER(COALESCE(JSON_VALUE(p.data, '$.stage'), '')) NOT IN (
    'trash', 'lead', 'attempted contact', 'under contract'
  )
),
ranked AS (
  SELECT
    person_id,
    first_name,
    last_name,
    stage,
    assigned_agent,
    pond_name,
    propensity_score,
    attribute_overlap * LN(1 + engagement_intensity * account_age_ramp * comms_boost) AS baseline_match_score,
    attribute_overlap * LN(1 + engagement_intensity * account_age_ramp * comms_boost * propensity_boost) AS boosted_match_score
  FROM matches
),
with_ranks AS (
  SELECT
    *,
    RANK() OVER (ORDER BY baseline_match_score DESC) AS baseline_rank,
    RANK() OVER (ORDER BY boosted_match_score DESC)  AS boosted_rank
  FROM ranked
)
SELECT
  baseline_rank,
  boosted_rank,
  baseline_rank - boosted_rank AS rank_change,  -- positive = moved up with propensity
  first_name,
  last_name,
  propensity_score,
  stage,
  assigned_agent,
  pond_name,
  baseline_match_score,
  boosted_match_score
FROM with_ranks
WHERE baseline_rank <= @limit OR boosted_rank <= @limit
ORDER BY boosted_rank;
