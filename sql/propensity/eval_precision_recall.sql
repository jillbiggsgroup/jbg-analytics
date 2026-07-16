-- Phase 4, step 4 (follow-up): the metric that actually answers "is this
-- deployable" -- precision at the top of the ranking, plus a properly
-- SQL-computed PR-AUC -- rather than roc_auc/accuracy, which both look
-- misleadingly good under ~0.05% class imbalance (roc_auc is threshold-
-- and prevalence-invariant; accuracy is dominated by the huge majority
-- class). Both queries below run against the WHERE is_eval rows from
-- model_buyer_propensity.sql's CUSTOM split -- a real, person-level held-
-- out set, not rows the model could have partially seen via another week
-- of the same person in training.

-- Precision@top-N: "if we hand agents the top N highest-scored leads, what
-- fraction actually transacted (within this label's 60-day window)?" This
-- is the number that determines whether the matcher gate/boost is useful,
-- not a global threshold like 0.5 -- BQML's default is a poor fit for a
-- problem this imbalanced (see 2026-07-16 critique: at 0.5, precision is
-- ~1%, and that's expected given the ~1:1900 base rate, not evidence the
-- ranking itself is bad).
WITH scored_eval AS (
  SELECT
    label,
    (SELECT prob FROM UNNEST(predicted_label_probs) WHERE label = 1) AS propensity_score
  FROM ML.PREDICT(
    MODEL `jbg-analytics.propensity.model_buyer_propensity`,
    (SELECT * FROM `jbg-analytics.propensity.training_examples_snapshot` WHERE is_eval)
  )
),
-- rn must be computed in its own CTE first: this model's top scores have
-- heavy ties (dozens of people sharing the same max propensity_score), and
-- SUM(...) OVER (ORDER BY propensity_score DESC) uses the default RANGE
-- frame, which lumps every tied row into one peer group instead of a true
-- running total. Summing ORDER BY the unique rn (computed here) instead of
-- ORDER BY propensity_score avoids that.
ranked AS (
  SELECT
    label,
    ROW_NUMBER() OVER (ORDER BY propensity_score DESC) AS rn
  FROM scored_eval
),
cumulative AS (
  SELECT
    rn,
    SUM(label) OVER (ORDER BY rn) AS cume_true_positives
  FROM ranked
)
SELECT
  rn AS top_n,
  cume_true_positives,
  cume_true_positives / rn AS precision_at_n
FROM cumulative
WHERE rn IN (100, 500, 1000, 5000, 10000, 25000, 50000, 100000)
ORDER BY rn;

-- PR-AUC: BQML's ML.EVALUATE doesn't return a pr_auc field directly (only
-- roc_auc), so this derives it from ML.ROC_CURVE's per-threshold
-- true_positives/false_positives -- precision = tp / (tp + fp) at each
-- threshold, then trapezoidal integration over recall. This is the SQL-
-- computed equivalent of the number the BigQuery console's model
-- evaluation UI shows on its PR-curve tab.
WITH curve AS (
  SELECT
    recall,
    SAFE_DIVIDE(true_positives, true_positives + false_positives) AS precision
  FROM ML.ROC_CURVE(
    MODEL `jbg-analytics.propensity.model_buyer_propensity`,
    (SELECT * FROM `jbg-analytics.propensity.training_examples_snapshot` WHERE is_eval),
    GENERATE_ARRAY(0, 1, 0.001)
  )
),
-- Precision is undefined (SAFE_DIVIDE -> NULL) at recall=0, where
-- true_positives=false_positives=0 -- conventionally treated as 1.0
-- (nothing flagged yet, so nothing flagged wrong) so the curve starts
-- at (recall=0, precision=1) rather than leaving a gap.
filled AS (
  SELECT recall, COALESCE(precision, 1.0) AS precision
  FROM curve
),
trapezoids AS (
  SELECT
    recall,
    precision,
    LAG(recall) OVER (ORDER BY recall)    AS prev_recall,
    LAG(precision) OVER (ORDER BY recall) AS prev_precision
  FROM filled
)
SELECT
  SUM((recall - prev_recall) * (precision + prev_precision) / 2) AS pr_auc
FROM trapezoids
WHERE prev_recall IS NOT NULL;
