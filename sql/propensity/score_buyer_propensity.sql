-- Phase 4, step 5: score the current live population.
--
-- Calls tvf_propensity_features with a single target date (today) rather
-- than the training spine's many weekly dates -- one feature row per
-- currently-live person, not one per (person, historical week). This is the
-- same feature logic used for training (see tvf_propensity_features.sql's
-- point-in-time-correctness notes), just invoked at today's as_of_date so
-- ML.PREDICT scores against live, current data.
--
-- CREATE OR REPLACE (not INSERT/append): this table always holds the
-- CURRENT propensity score per person, not a score history. Step 6's daily
-- refresh re-runs this same statement. If historical score trends are
-- needed later, add a separate append-only table then -- not needed for the
-- v1 end-to-end pipeline.
--
-- predicted_label_probs holds one row per class (label was trained as
-- INT64 0/1), so pulling the label=1 probability out of that array gives a
-- single 0-1 propensity_score column -- the number the matcher gates/ranks
-- on in step 7, not predicted_label (which is thresholded at 0.5 and, per
-- eval_buyer_propensity.sql's note, not meaningful at that threshold for
-- this imbalanced a label).

CREATE OR REPLACE TABLE `jbg-analytics.propensity.scores_buyer_propensity` AS
SELECT
  person_id,
  as_of_date                                                        AS scored_as_of,
  (SELECT prob FROM UNNEST(predicted_label_probs) WHERE label = 1)  AS propensity_score
FROM ML.PREDICT(
  MODEL `jbg-analytics.propensity.model_buyer_propensity`,
  (
    SELECT *
    FROM `jbg-analytics.propensity.tvf_propensity_features`(ARRAY[CURRENT_DATE()])
  )
);
