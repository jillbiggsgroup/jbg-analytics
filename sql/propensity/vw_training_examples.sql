-- Phase 4, step 2 (cont.): labeled training table -- joins each
-- (person_id, as_of_date) row from vw_transaction_labels to its features from
-- tvf_propensity_features, called once with the label spine's distinct
-- as_of_dates (not per-row) so the feature computation runs once per week,
-- not once per label row. This is the table CREATE MODEL trains on in step 3.

CREATE OR REPLACE VIEW `jbg-analytics.propensity.vw_training_examples` AS
SELECT
  l.person_id,
  l.as_of_date,
  l.label,
  f.* EXCEPT(person_id, as_of_date)
FROM `jbg-analytics.propensity.vw_transaction_labels` l
JOIN `jbg-analytics.propensity.tvf_propensity_features`(
  ARRAY(SELECT DISTINCT as_of_date FROM `jbg-analytics.propensity.vw_transaction_labels`)
) f
  ON f.person_id = l.person_id AND f.as_of_date = l.as_of_date;
