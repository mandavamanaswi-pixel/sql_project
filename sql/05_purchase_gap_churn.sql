-- =====================================================================
-- 05_purchase_gap_churn.sql  |  Churn definition, trigger days, cohort matrix
-- Question: how long do customers normally wait between orders, and
--           when should marketing step in? (Data-driven, not guessed.)
-- Skills: LAG(), ROW_NUMBER(), percentiles in MySQL, views, pivoting
-- =====================================================================
USE shopsphere;

-- ---------------------------------------------------------------------
-- A. Days between consecutive purchases per customer (LAG)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_purchase_gaps AS
SELECT customer_id, order_id, order_date,
       ROW_NUMBER() OVER w                                  AS order_seq,
       LAG(order_date) OVER w                               AS prev_order_date,
       DATEDIFF(order_date, LAG(order_date) OVER w)         AS days_since_prev
FROM orders
WHERE status = 'completed'
WINDOW w AS (PARTITION BY customer_id ORDER BY order_date, order_id);

-- ---------------------------------------------------------------------
-- B. Percentiles of the gap distribution (MySQL has no PERCENTILE_CONT,
--    so rank rows and pick the first row at or above each percentile)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_gap_thresholds AS
WITH g AS (
    SELECT days_since_prev AS d,
           ROW_NUMBER() OVER (ORDER BY days_since_prev) AS rn,
           COUNT(*) OVER ()                             AS n
    FROM v_purchase_gaps
    WHERE days_since_prev IS NOT NULL
)
SELECT COUNT(*)                                       AS repeat_purchases,
       ROUND(AVG(d), 1)                               AS avg_gap_days,
       MIN(CASE WHEN rn >= CEIL(n * 0.50) THEN d END) AS p50_days,
       MIN(CASE WHEN rn >= CEIL(n * 0.75) THEN d END) AS p75_days,
       MIN(CASE WHEN rn >= CEIL(n * 0.90) THEN d END) AS p90_days
FROM g;

-- ---------------------------------------------------------------------
-- C. Lifecycle stage per customer, driven by the thresholds above
--    Active   : inactive for <= median gap (still within normal rhythm)
--    At Risk  : past the median gap but within the 90th percentile
--    Churned  : inactive longer than 90% of repeat purchases ever took
--    (analysis date = 2025-10-31, the end of the dataset)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_customer_lifecycle AS
SELECT l.customer_id, c.channel, l.orders, l.last_order_date,
       DATEDIFF('2025-10-31', l.last_order_date) AS days_inactive,
       v.revenue,
       CASE WHEN DATEDIFF('2025-10-31', l.last_order_date) <= t.p50_days THEN '1-Active'
            WHEN DATEDIFF('2025-10-31', l.last_order_date) <= t.p90_days THEN '2-At Risk'
            ELSE '3-Churned' END AS lifecycle_stage
FROM (SELECT customer_id, COUNT(*) AS orders, MAX(order_date) AS last_order_date
      FROM orders WHERE status = 'completed' GROUP BY customer_id) l
JOIN customers c USING (customer_id)
JOIN (SELECT customer_id, SUM(revenue) AS revenue
      FROM v_order_lines WHERE status = 'completed' GROUP BY customer_id) v USING (customer_id)
CROSS JOIN v_gap_thresholds t;

-- =====================================================================
-- ANALYSIS
-- =====================================================================

-- Q1. How long between orders? (average, median, 75th and 90th percentile)
SELECT * FROM v_gap_thresholds;

-- Q2. Does the wait shrink as customers get more loyal? (1->2 vs 2->3 vs 3->4+)
SELECT CASE WHEN order_seq >= 4 THEN '4th order or later'
            ELSE CONCAT('Order ', order_seq - 1, ' -> ', order_seq) END AS transition_step,
       COUNT(*)                         AS purchases,
       ROUND(AVG(days_since_prev), 1)   AS avg_gap_days
FROM v_purchase_gaps
WHERE order_seq >= 2
GROUP BY transition_step
ORDER BY MIN(order_seq);

-- Q3. Distribution of gaps in 30-day buckets with cumulative share
SELECT CONCAT(bucket_start, '-', bucket_start + 29, ' days') AS gap_bucket,
       purchases,
       ROUND(100 * purchases / SUM(purchases) OVER (), 1)                         AS pct_of_repeat_orders,
       ROUND(100 * SUM(purchases) OVER (ORDER BY bucket_start) / SUM(purchases) OVER (), 1) AS cumulative_pct
FROM (SELECT FLOOR(days_since_prev / 30) * 30 AS bucket_start, COUNT(*) AS purchases
      FROM v_purchase_gaps
      WHERE days_since_prev IS NOT NULL
      GROUP BY bucket_start) b
ORDER BY bucket_start;

-- Q4. Lifecycle summary: how much revenue sits in each stage?
SELECT lifecycle_stage,
       COUNT(*)                                                  AS customers,
       ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)          AS pct_customers,
       ROUND(SUM(revenue), 0)                                    AS lifetime_revenue,
       ROUND(100 * SUM(revenue) / SUM(SUM(revenue)) OVER (), 1)  AS pct_revenue,
       ROUND(AVG(days_inactive), 0)                              AS avg_days_inactive
FROM v_customer_lifecycle
GROUP BY lifecycle_stage
ORDER BY lifecycle_stage;

-- Q5. Which acquisition channels leak the most customers?
SELECT channel,
       COUNT(*)                                                         AS buyers,
       ROUND(100 * SUM(lifecycle_stage = '1-Active')  / COUNT(*), 1)    AS pct_active,
       ROUND(100 * SUM(lifecycle_stage = '2-At Risk') / COUNT(*), 1)    AS pct_at_risk,
       ROUND(100 * SUM(lifecycle_stage = '3-Churned') / COUNT(*), 1)    AS pct_churned
FROM v_customer_lifecycle
GROUP BY channel
ORDER BY pct_churned DESC;

-- Q6. THE RECOMMENDATION: exact day-marks to trigger campaigns
SELECT 1 AS step, 'Friendly reminder (email)'          AS campaign, p50_days AS trigger_day,
       'Half of repeat orders happen by now; nudge before the habit fades' AS rationale
FROM v_gap_thresholds
UNION ALL
SELECT 2, 'Win-back offer (discount code)', p75_days,
       '75% of repeat orders are done; silence beyond this is unusual'
FROM v_gap_thresholds
UNION ALL
SELECT 3, 'Last-chance / survey (why did you leave?)', p90_days,
       'Beyond 90% of normal repeat gaps: customer treated as churned'
FROM v_gap_thresholds
ORDER BY step;

-- Q7. Cohort matrix: % of each first-order-month cohort that buys again
--     in month +1 ... +6 (NULL = that month has not happened yet)
WITH first_order AS (
    SELECT customer_id, DATE_FORMAT(MIN(order_date), '%Y-%m-01') AS cohort_month
    FROM orders WHERE status = 'completed'
    GROUP BY customer_id
), activity AS (
    SELECT DISTINCT o.customer_id, f.cohort_month,
           TIMESTAMPDIFF(MONTH, f.cohort_month, o.order_date) AS m
    FROM orders o
    JOIN first_order f USING (customer_id)
    WHERE o.status = 'completed'
)
SELECT cohort_month,
       COUNT(DISTINCT CASE WHEN m = 0 THEN customer_id END) AS cohort_size,
       CASE WHEN TIMESTAMPDIFF(MONTH, cohort_month, '2025-10-01') < 1 THEN NULL
            ELSE ROUND(100 * COUNT(DISTINCT CASE WHEN m = 1 THEN customer_id END)
                       / COUNT(DISTINCT CASE WHEN m = 0 THEN customer_id END), 1) END AS M1,
       CASE WHEN TIMESTAMPDIFF(MONTH, cohort_month, '2025-10-01') < 2 THEN NULL
            ELSE ROUND(100 * COUNT(DISTINCT CASE WHEN m = 2 THEN customer_id END)
                       / COUNT(DISTINCT CASE WHEN m = 0 THEN customer_id END), 1) END AS M2,
       CASE WHEN TIMESTAMPDIFF(MONTH, cohort_month, '2025-10-01') < 3 THEN NULL
            ELSE ROUND(100 * COUNT(DISTINCT CASE WHEN m = 3 THEN customer_id END)
                       / COUNT(DISTINCT CASE WHEN m = 0 THEN customer_id END), 1) END AS M3,
       CASE WHEN TIMESTAMPDIFF(MONTH, cohort_month, '2025-10-01') < 4 THEN NULL
            ELSE ROUND(100 * COUNT(DISTINCT CASE WHEN m = 4 THEN customer_id END)
                       / COUNT(DISTINCT CASE WHEN m = 0 THEN customer_id END), 1) END AS M4,
       CASE WHEN TIMESTAMPDIFF(MONTH, cohort_month, '2025-10-01') < 5 THEN NULL
            ELSE ROUND(100 * COUNT(DISTINCT CASE WHEN m = 5 THEN customer_id END)
                       / COUNT(DISTINCT CASE WHEN m = 0 THEN customer_id END), 1) END AS M5,
       CASE WHEN TIMESTAMPDIFF(MONTH, cohort_month, '2025-10-01') < 6 THEN NULL
            ELSE ROUND(100 * COUNT(DISTINCT CASE WHEN m = 6 THEN customer_id END)
                       / COUNT(DISTINCT CASE WHEN m = 0 THEN customer_id END), 1) END AS M6
FROM activity
GROUP BY cohort_month
HAVING cohort_size >= 10          -- tiny cohorts give noisy percentages
ORDER BY cohort_month;

-- Q8. Marketing target list: highest-value customers currently 'At Risk'
SELECT customer_id, channel, orders, last_order_date, days_inactive,
       ROUND(revenue, 2) AS lifetime_revenue
FROM v_customer_lifecycle
WHERE lifecycle_stage = '2-At Risk'
ORDER BY revenue DESC
LIMIT 15;
