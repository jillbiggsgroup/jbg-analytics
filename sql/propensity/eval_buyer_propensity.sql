-- Phase 4, step 4: evaluate the trained model. Run after
-- model_buyer_propensity.sql completes.
--
-- ML.EVALUATE with no query arg uses BQML's own AUTO_SPLIT eval slice (the
-- portion CREATE MODEL held out internally), so results are directly
-- comparable to what CREATE MODEL logged during training.
--
-- Threshold 0.5 is ML.EVALUATE's default; with auto_class_weights=TRUE the
-- loss was reweighted for imbalance but the classification threshold wasn't,
-- so precision/recall at 0.5 may look off for a ~0.05%-positive population --
-- expected, not a bug. roc_auc is threshold-independent and is the number to
-- judge the model on for this step (target: aim > 0.70, per spec).

SELECT *
FROM ML.EVALUATE(MODEL `jbg-analytics.propensity.model_buyer_propensity`);

-- Confirms the model isn't leaning entirely on recency (days_since_last_event
-- / days_since_last_two_way_contact) -- per spec's guardrail against a model
-- that's just recency in disguise. Check relative attributed importance
-- across ALL features, not just the top row.

SELECT *
FROM ML.FEATURE_IMPORTANCE(MODEL `jbg-analytics.propensity.model_buyer_propensity`)
ORDER BY importance_weight DESC;

-- Confusion matrix at the default 0.5 threshold -- sanity check that the
-- model is predicting SOME positives, not just always 0 despite class
-- weighting.

SELECT *
FROM ML.CONFUSION_MATRIX(MODEL `jbg-analytics.propensity.model_buyer_propensity`);
