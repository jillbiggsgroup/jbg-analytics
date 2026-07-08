-- Phase 1: enriched events base view.
-- Joins FUB events to HCMLS listings on MLS number, falls back to event payload
-- attributes when the join misses, classifies intent, and flags rentals.
-- See spec §4 for field mapping and rationale.

CREATE OR REPLACE VIEW `jbg-analytics.matching.vw_enriched_events` AS
WITH hcmls AS (
  SELECT
    JSON_VALUE(data, '$.mapped.mls')                                AS mls_number,
    JSON_VALUE(data, '$.mapped.type')                               AS property_type,
    JSON_VALUE(data, '$.mapped.class')                              AS property_class,
    SAFE_CAST(JSON_VALUE(data, '$.mapped.LM_Int1_4') AS INT64)      AS beds,
    SAFE_CAST(JSON_VALUE(data, '$.mapped.LM_Int2_1') AS NUMERIC)    AS baths,
    SAFE_CAST(JSON_VALUE(data, '$.mapped.asking_price') AS INT64)   AS price,
    JSON_VALUE(data, '$.mapped.city')                               AS city,
    JSON_VALUE(data, '$.mapped.state')                              AS state,
    JSON_VALUE(data, '$.mapped.zip')                                AS zip,
    JSON_VALUE(data, '$.mapped.county')                             AS county,
    SAFE_CAST(JSON_VALUE(data, '$.mapped.geo_latitude')  AS FLOAT64) AS lat,
    SAFE_CAST(JSON_VALUE(data, '$.mapped.geo_longitude') AS FLOAT64) AS lng,
    JSON_VALUE(data, '$.mapped.status')                             AS status,
    JSON_VALUE(data, '$.mapped.status_category')                    AS status_category,
    JSON_QUERY_ARRAY(data, '$.raw.LFD_PARKINGAVAILABLE_3')          AS parking,
    JSON_QUERY_ARRAY(data, '$.raw.LFD_BUILDINGSTYLE_2')             AS building_style,
    JSON_QUERY_ARRAY(data, '$.raw.LFD_AMENITIESINCLUDE_8')          AS amenities,
    JSON_QUERY_ARRAY(data, '$.raw.LFD_MISCELLANEOUS_9')             AS miscellaneous,
    JSON_VALUE(data, '$.raw.LR_remarks1010')                        AS remarks
  FROM `hcmls-mirror.hcmls_listings.listings_raw_latest`
),
events AS (
  SELECT
    JSON_VALUE(data, '$.personId')                                  AS person_id,
    JSON_VALUE(data, '$.type')                                      AS event_type,
    JSON_VALUE(data, '$.source')                                    AS event_source,
    SAFE_CAST(JSON_VALUE(data, '$.occurred') AS TIMESTAMP)          AS occurred_at,
    NULLIF(JSON_VALUE(data, '$.property.mlsNumber'), '')            AS payload_mls,
    JSON_VALUE(data, '$.property.state')                            AS payload_state,
    SAFE_CAST(JSON_VALUE(data, '$.property.price')     AS INT64)    AS payload_price,
    SAFE_CAST(JSON_VALUE(data, '$.property.bedrooms')  AS INT64)    AS payload_beds,
    SAFE_CAST(JSON_VALUE(data, '$.property.bathrooms') AS NUMERIC)  AS payload_baths,
    JSON_VALUE(data, '$.property.city')                             AS payload_city,
    JSON_VALUE(data, '$.property.street')                           AS payload_street,
    NULLIF(JSON_VALUE(data, '$.property.type'), '')                 AS payload_type,
    SAFE_CAST(JSON_VALUE(data, '$.property.forRent')  AS INT64)     AS payload_for_rent,
    SAFE_CAST(JSON_VALUE(data, '$.property.id')       AS INT64)     AS payload_property_id
  FROM `jbg-fub-events-mirror.events_mirror.events_raw_latest`
  WHERE JSON_VALUE(data, '$.property.state') = 'NJ'
    AND COALESCE(JSON_VALUE(data, '$.type'), '') != ''  -- exclude legacy junk
)
SELECT
  e.person_id,
  e.event_type,
  e.event_source,
  e.occurred_at,
  COALESCE(h.beds,  e.payload_beds)  AS beds,
  COALESCE(h.baths, e.payload_baths) AS baths,
  COALESCE(h.price, e.payload_price) AS price,
  COALESCE(h.city,  e.payload_city)  AS city,
  h.county,
  h.zip,
  h.lat,
  h.lng,
  COALESCE(
    h.property_type,
    e.payload_type,
    CASE
      WHEN REGEXP_CONTAINS(LOWER(e.payload_street),
             r'(?:\bapt\b|\bunit\b|\bph\s*\d|#\s*\w|\s\d+-\d+$|\s\d+[a-z]$)')
        THEN 'Condo (inferred)'
    END
  ) AS property_type,
  h.parking,
  h.building_style,
  h.amenities,
  h.miscellaneous,
  h.remarks,
  h.status,
  h.status_category,
  e.payload_street,
  e.payload_mls,
  e.payload_property_id,
  CASE WHEN COALESCE(h.price, e.payload_price) < 15000 THEN TRUE ELSE FALSE END AS is_rental,
  CASE
    WHEN e.event_type IN ('Property Inquiry','Seller Inquiry','General Inquiry',
                          'Virtually Toured Property','Visited Open House',
                          'Phone Call','Text','Felix AI Handoff','Pre-Approval')
      THEN 'high_intent'
    WHEN e.event_type IN ('Saved Property','Shared Property','Registration')
      THEN 'medium_intent'
    WHEN e.event_type IN ('Viewed Property','Viewed Page','Visited Website')
      THEN 'browsing'
    WHEN e.event_type IN ('Hid Property','Unsaved')
      THEN 'negative'
    ELSE 'other'
  END AS intent_class,
  CASE
    WHEN h.mls_number IS NOT NULL   THEN 'hcmls'
    WHEN e.payload_price IS NOT NULL THEN 'payload'
    ELSE                                 'minimal'
  END AS enrichment_tier
FROM events e
LEFT JOIN hcmls h
  ON e.payload_mls = h.mls_number
