-- Phase 4, step 7: matcher output gated/re-ranked by buyer propensity score.
-- Layers on top of match_listing_with_names.sql (Phase 3, §7.4) -- this is a
-- NEW file, not an edit to the live matcher. Per the propensity spec's
-- guardrail: get sign-off from Dan before this replaces the live matcher
-- query. Until then, this is for side-by-side testing only.
--
-- Gate (@propensity_threshold): nullable, defaults to disabling the gate
-- entirely so this can be evaluated purely as a re-ranking change first,
-- with hard filtering only turned on once a threshold is agreed on. A
-- person with no score yet (scored_buyer_propensity refreshes once daily,
-- see score_buyer_propensity.sql -- someone created after the last refresh
-- won't have a row) fails OPEN, i.e. still passes the gate -- "no score
-- yet" reflects refresh latency, not evidence of low propensity, so it
-- shouldn't get a person excluded outright.
--
-- Boost (propensity_weight, in `constants`): propensity_score folds into
-- the SAME multiplier stack as account_age_ramp / comms_boost (all three
-- scale engagement_intensity before the LN, rather than each being bolted
-- onto match_score separately) so a genuinely high-propensity person's
-- log-scaled engagement term gets scaled up without needing to renormalize
-- attribute_overlap. A missing score defaults the boost to 1.0 (neutral --
-- no change), the same fail-open posture as the gate, not a penalty.

-- Parameters (same as match_listing_with_names.sql, plus):
-- @target_price      INT64
-- @target_beds       INT64
-- @target_baths      NUMERIC
-- @target_city       STRING
-- @target_property_type STRING     -- e.g. 'One Family', 'Condo', 'Condominium'
-- @target_county     STRING        -- e.g. 'Hudson'
-- @target_has_parking BOOL
-- @limit             INT64         -- e.g. 25
-- @propensity_threshold FLOAT64    -- e.g. 0.3; pass NULL to disable gating

WITH constants AS (
  SELECT
    3.0 AS account_age_grace_days,  -- days for a new contact to reach full weight
    14.0 AS comms_half_life_days,   -- days for the recent-comms boost to decay by half
    0.5 AS comms_boost_weight,      -- max fractional boost to engagement_intensity from recent comms
    1.0 AS propensity_weight        -- max fractional boost to engagement_intensity from propensity_score
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
-- Join to names/stage/propensity before ranking so an excluded stage (e.g.
-- Trash) or a gated-out low-propensity person can't occupy one of the
-- top-N slots and shrink the usable result count below @limit.
matches AS (
  SELECT
    ps.person_id,
    ps.attribute_overlap,
    ps.n_matching_events,
    ps.engagement_intensity,
    sc.propensity_score,
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
    -- Comms recency boost: a contact who recently emailed/texted/messaged
    -- the team back is showing live engagement outside of property
    -- browsing, so give engagement_intensity a decaying boost on top of it.
    -- Same EXP(-LN(2)*days/half_life) decay used for event recency in
    -- vw_person_fingerprints.sql. No comms on record decays toward a
    -- ~1970 timestamp, so the boost underflows to 0 (fails open to no
    -- boost, not a penalty) rather than needing a separate NULL branch.
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
    -- Propensity boost: same shape as comms_boost -- a multiplier on
    -- engagement_intensity, not a separate additive term. A missing score
    -- (person not yet in today's scores table) defaults to 0, so the boost
    -- is 1.0 -- neutral, not a penalty.
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
  -- Gate: NULL threshold disables gating entirely. A person with no score
  -- yet always passes (refresh latency, not a signal of low propensity).
  AND (
    @propensity_threshold IS NULL
    OR sc.propensity_score IS NULL
    OR sc.propensity_score >= @propensity_threshold
  )
)
SELECT
  attribute_overlap * LN(1 + engagement_intensity * account_age_ramp * comms_boost * propensity_boost) AS match_score,
  propensity_score,
  first_name,
  last_name,
  stage,
  assigned_agent,
  pond_name,
  CONCAT('https://jillkbiggs.followupboss.com/2/people/view/', person_id) AS profile_url
FROM matches
ORDER BY match_score DESC
LIMIT @limit;
