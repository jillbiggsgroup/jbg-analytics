-- Phase 4, step 3: train the buyer propensity model.
--
-- Snapshot first (2026-07-15): vw_training_examples recomputes the full
-- events/calls/texts/emails join (9M+ rows) every time it's queried. Since
-- CREATE MODEL will scan it at least once for training and again internally
-- for the auto eval split, materializing to a table first avoids paying for
-- that join twice and gives a stable, reproducible snapshot to iterate
-- against while tuning.
--
-- Class imbalance (confirmed 2026-07-15): 9,079,412 label=0 rows vs. 4,806
-- label=1 rows (~0.053% positive) in vw_training_examples. A boosted tree
-- trained without correction will lean toward always predicting 0 and still
-- post a deceptively high raw accuracy -- auto_class_weights=TRUE reweights
-- the loss inversely to class frequency so the minority (transacted) class
-- isn't drowned out.
--
-- Columns excluded from training on purpose: person_id and as_of_date are
-- row identifiers, not predictive features -- including person_id would let
-- the model memorize individual IDs (a high-cardinality categorical with no
-- generalization value) instead of learning from behavior.
--
-- `stage` dropped after first training run (2026-07-16): ML.EVALUATE came
-- back with roc_auc 0.998 and ML.FEATURE_IMPORTANCE showed stage's
-- importance_gain (97,024) an order of magnitude above every other feature --
-- the leakage signature the header note above already warned about.
-- mirror_people_raw_latest is current-state, so anyone who has since
-- transacted shows their POST-transaction stage (e.g. Closed) on every
-- historical training row for that person, not their stage as of that row's
-- as_of_date. That's post-outcome information leaking into training, which
-- the spec's guardrail explicitly rules out. Until a point-in-time-correct
-- stage (from a changelog, the way calls/texts are handled) is built, stage
-- is excluded rather than trained on a leaky proxy. `source` is left in --
-- it's set once at lead creation and doesn't change over the lead's
-- lifecycle, so it doesn't carry this same forward-leak risk.
--
-- training_examples_snapshot itself doesn't need to be rebuilt for this --
-- it already has the stage column; only the CREATE MODEL SELECT below
-- changes, so this is a straight retrain from the existing snapshot.

CREATE OR REPLACE TABLE `jbg-analytics.propensity.training_examples_snapshot` AS
SELECT *
FROM `jbg-analytics.propensity.vw_training_examples`;

-- data_split_method (2026-07-16): switched from AUTO_SPLIT to an explicit
-- RANDOM split w/ a fixed eval fraction. AUTO_SPLIT trained fine (see
-- ML.TRAINING_INFO -- eval_loss converged normally from 0.466 to 0.077 over
-- 16 iterations) but didn't leave behind an official held-out set for
-- ML.EVALUATE / ML.CONFUSION_MATRIX to use (distinct from the internal
-- early-stopping validation slice that produces TRAINING_INFO's eval_loss
-- column). Forcing RANDOM + data_split_eval_fraction guarantees ML.EVALUATE
-- has real held-out data to score against.
CREATE OR REPLACE MODEL `jbg-analytics.propensity.model_buyer_propensity`
OPTIONS (
  model_type = 'BOOSTED_TREE_CLASSIFIER',
  input_label_cols = ['label'],
  auto_class_weights = TRUE,
  data_split_method = 'RANDOM',
  data_split_eval_fraction = 0.2
) AS
SELECT
  label,
  days_since_created,
  source,
  events_30d,
  events_60d,
  events_90d,
  inquiries_30d,
  inquiries_90d,
  high_intent_events_30d,
  distinct_listings_30d,
  distinct_listings_60d,
  distinct_listings_90d,
  trend_30_vs_prior30,
  days_since_last_event,
  calls_incoming_30d,
  calls_incoming_90d,
  calls_connected_30d,
  calls_connected_90d,
  texts_incoming_30d,
  texts_incoming_90d,
  emails_from_person_30d,
  emails_from_person_90d,
  email_opens_30d,
  email_opens_90d,
  email_clicks_30d,
  email_clicks_90d,
  days_since_last_two_way_contact
FROM `jbg-analytics.propensity.training_examples_snapshot`;
