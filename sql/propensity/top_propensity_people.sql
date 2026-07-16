-- Phase 4, step 5 (follow-up): top people by propensity score alone, no
-- listing-match parameters -- for spot-checking scores_buyer_propensity.sql
-- output and answering "who are our best leads right now" directly, as
-- opposed to match_listing_with_propensity.sql (Phase 4, step 7) which
-- blends propensity into a specific listing match and needs @target_*
-- params to run.
--
-- Same name/stage/agent join pattern as match_listing_with_names.sql.
-- Trash/Lead/Attempted Contact/Under Contract excluded the same way the
-- matcher excludes them, so this reflects people an agent could actually
-- act on today, not raw score-table rows.

-- Parameters:
-- @limit INT64   -- e.g. 100

SELECT
  sc.propensity_score,
  sc.scored_as_of,
  JSON_VALUE(p.data, '$.firstName')  AS first_name,
  JSON_VALUE(p.data, '$.lastName')   AS last_name,
  JSON_VALUE(p.data, '$.stage')      AS stage,
  JSON_VALUE(p.data, '$.assignedTo') AS assigned_agent,
  CONCAT('https://jillkbiggs.followupboss.com/2/people/view/', sc.person_id) AS profile_url
FROM `jbg-analytics.propensity.scores_buyer_propensity` sc
LEFT JOIN `jbg-fub-mirror.fub_mirror_people.mirror_people_raw_latest` p
  ON JSON_VALUE(p.data, '$.id') = sc.person_id
WHERE LOWER(COALESCE(JSON_VALUE(p.data, '$.stage'), '')) NOT IN (
  'trash', 'lead', 'attempted contact', 'under contract'
)
ORDER BY sc.propensity_score DESC
LIMIT @limit;
