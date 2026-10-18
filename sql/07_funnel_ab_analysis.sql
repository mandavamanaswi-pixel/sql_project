-- =====================================================================
-- 07_funnel_ab_analysis.sql  |  Conversion funnel + A/B test
-- Skills: event-log pivoting, funnel metrics, LAG over aggregates,
--         two-proportion z-test, confidence interval, power check in SQL
-- =====================================================================
USE shopsphere;

-- Q1. Overall funnel with step-to-step and overall conversion
SELECT event_type AS step,
       COUNT(DISTINCT session_id) AS sessions,
       ROUND(100 * COUNT(DISTINCT session_id)
             / LAG(COUNT(DISTINCT session_id)) OVER (ORDER BY FIELD(event_type,'visit','product_view','add_to_cart','begin_checkout','purchase')), 1) AS pct_of_previous_step,
       ROUND(100 * COUNT(DISTINCT session_id)
             / FIRST_VALUE(COUNT(DISTINCT session_id)) OVER (ORDER BY FIELD(event_type,'visit','product_view','add_to_cart','begin_checkout','purchase')), 1) AS pct_of_all_visits
FROM web_events
GROUP BY event_type
ORDER BY FIELD(event_type,'visit','product_view','add_to_cart','begin_checkout','purchase');

-- Q2. Where is the biggest leak? (drop-off at every step, ranked)
WITH s AS (SELECT SUM(visited) v, SUM(viewed) pv, SUM(carted) c, SUM(checkout) co, SUM(purchased) p
           FROM v_session_funnel)
SELECT step, sessions_lost, drop_off_pct FROM (
    SELECT 'Visit -> Product view'      AS step, v  - pv AS sessions_lost, ROUND(100*(v-pv)/v, 1)   AS drop_off_pct FROM s
    UNION ALL SELECT 'Product view -> Add to cart',  pv - c,  ROUND(100*(pv-c)/pv, 1)   FROM s
    UNION ALL SELECT 'Add to cart -> Checkout',      c  - co, ROUND(100*(c-co)/c, 1)    FROM s
    UNION ALL SELECT 'Checkout -> Purchase',         co - p,  ROUND(100*(co-p)/co, 1)   FROM s
) t
ORDER BY drop_off_pct DESC;

-- Q3. Funnel by device
SELECT device,
       COUNT(*)                                                   AS sessions,
       ROUND(100 * SUM(viewed)   / SUM(visited), 1)               AS view_rate,
       ROUND(100 * SUM(carted)   / SUM(viewed), 1)                AS cart_rate,
       ROUND(100 * SUM(checkout) / SUM(carted), 1)                AS checkout_rate,
       ROUND(100 * SUM(purchased)/ SUM(checkout), 1)              AS purchase_rate,
       ROUND(100 * SUM(purchased)/ COUNT(*), 2)                   AS overall_conversion_pct
FROM v_session_funnel
GROUP BY device
ORDER BY overall_conversion_pct DESC;

-- Q4. Funnel by acquisition channel
SELECT channel,
       COUNT(*)                                                   AS sessions,
       ROUND(100 * SUM(viewed)   / SUM(visited), 1)               AS view_rate,
       ROUND(100 * SUM(carted)   / SUM(viewed), 1)                AS cart_rate,
       ROUND(100 * SUM(checkout) / SUM(carted), 1)                AS checkout_rate,
       ROUND(100 * SUM(purchased)/ SUM(checkout), 1)              AS purchase_rate,
       ROUND(100 * SUM(purchased)/ COUNT(*), 2)                   AS overall_conversion_pct
FROM v_session_funnel
GROUP BY channel
ORDER BY overall_conversion_pct DESC;

-- Q5. Weekly conversion trend (is the test period stable?)
SELECT YEARWEEK(session_date, 1)                  AS year_week,
       MIN(session_date)                          AS week_start,
       COUNT(*)                                   AS sessions,
       ROUND(100 * SUM(purchased) / COUNT(*), 2)  AS conversion_pct
FROM v_session_funnel
GROUP BY year_week
ORDER BY year_week;

-- =====================================================================
-- A/B TEST: checkout variant A (old) vs B (new one-page checkout)
-- Metric: purchase rate among sessions that reached checkout
-- =====================================================================

-- Q6. Result with lift, z-score and 95% confidence interval
WITH v AS (
    SELECT checkout_variant AS variant, SUM(checkout) AS n, SUM(purchased) AS x
    FROM v_session_funnel
    GROUP BY checkout_variant
), a AS (SELECT n AS n1, x AS x1 FROM v WHERE variant = 'A'),
   b AS (SELECT n AS n2, x AS x2 FROM v WHERE variant = 'B')
SELECT n1 AS checkouts_A, n2 AS checkouts_B,
       ROUND(100 * x1 / n1, 2)                                   AS conv_A_pct,
       ROUND(100 * x2 / n2, 2)                                   AS conv_B_pct,
       ROUND(100 * (x2/n2 - x1/n1), 2)                           AS lift_pct_points,
       ROUND(100 * ((x2/n2) / (x1/n1) - 1), 1)                   AS relative_lift_pct,
       ROUND((x2/n2 - x1/n1) /
             SQRT(((x1+x2)/(n1+n2)) * (1 - (x1+x2)/(n1+n2)) * (1/n1 + 1/n2)), 2) AS z_score,
       ROUND(100 * ((x2/n2 - x1/n1) - 1.96 * SQRT((x1/n1)*(1-x1/n1)/n1 + (x2/n2)*(1-x2/n2)/n2)), 2) AS ci95_low_pp,
       ROUND(100 * ((x2/n2 - x1/n1) + 1.96 * SQRT((x1/n1)*(1-x1/n1)/n1 + (x2/n2)*(1-x2/n2)/n2)), 2) AS ci95_high_pp,
       CASE WHEN ABS((x2/n2 - x1/n1) /
             SQRT(((x1+x2)/(n1+n2)) * (1 - (x1+x2)/(n1+n2)) * (1/n1 + 1/n2))) > 1.96
            THEN 'SIGNIFICANT at 95%' ELSE 'not significant' END AS verdict
FROM a CROSS JOIN b;

-- Q7. Was the test big enough? (rule of thumb: n per arm = 16 * p(1-p) / delta^2)
WITH v AS (
    SELECT checkout_variant AS variant, SUM(checkout) AS n, SUM(purchased) AS x
    FROM v_session_funnel GROUP BY checkout_variant
), a AS (SELECT n AS n1, x AS x1 FROM v WHERE variant = 'A'),
   b AS (SELECT n AS n2, x AS x2 FROM v WHERE variant = 'B')
SELECT LEAST(n1, n2)                                                       AS actual_n_per_arm,
       CEIL(16 * ((x1+x2)/(n1+n2)) * (1 - (x1+x2)/(n1+n2))
            / POW(x2/n2 - x1/n1, 2))                                       AS needed_n_per_arm_80pct_power,
       IF(LEAST(n1, n2) >= 16 * ((x1+x2)/(n1+n2)) * (1 - (x1+x2)/(n1+n2)) / POW(x2/n2 - x1/n1, 2),
          'Adequately powered', 'Underpowered: keep collecting data') AS power_check
FROM a CROSS JOIN b;

-- Q8. Does the new checkout help everywhere? (result by device)
SELECT device,
       SUM(CASE WHEN checkout_variant = 'A' THEN checkout END)                                AS checkouts_A,
       SUM(CASE WHEN checkout_variant = 'B' THEN checkout END)                                AS checkouts_B,
       ROUND(100 * SUM(CASE WHEN checkout_variant = 'A' THEN purchased END)
             / SUM(CASE WHEN checkout_variant = 'A' THEN checkout END), 2)                    AS conv_A_pct,
       ROUND(100 * SUM(CASE WHEN checkout_variant = 'B' THEN purchased END)
             / SUM(CASE WHEN checkout_variant = 'B' THEN checkout END), 2)                    AS conv_B_pct,
       ROUND(100 * (SUM(CASE WHEN checkout_variant = 'B' THEN purchased END)
                    / SUM(CASE WHEN checkout_variant = 'B' THEN checkout END)
                  - SUM(CASE WHEN checkout_variant = 'A' THEN purchased END)
                    / SUM(CASE WHEN checkout_variant = 'A' THEN checkout END)), 2)            AS lift_pct_points
FROM v_session_funnel
GROUP BY device
ORDER BY lift_pct_points DESC;

-- Q9. Business impact: extra revenue per 10,000 checkout starts if B ships
--     (uses the real average order value from the orders data)
WITH v AS (
    SELECT checkout_variant AS variant, SUM(checkout) AS n, SUM(purchased) AS x
    FROM v_session_funnel GROUP BY checkout_variant
), a AS (SELECT n AS n1, x AS x1 FROM v WHERE variant = 'A'),
   b AS (SELECT n AS n2, x AS x2 FROM v WHERE variant = 'B'),
   aov AS (SELECT SUM(revenue) / COUNT(DISTINCT order_id) AS avg_order_value
           FROM v_order_lines WHERE status = 'completed')
SELECT ROUND(10000 * (x2/n2 - x1/n1), 0)                         AS extra_orders_per_10k_checkouts,
       ROUND(aov.avg_order_value, 2)                             AS avg_order_value,
       ROUND(10000 * (x2/n2 - x1/n1) * aov.avg_order_value, 0)   AS extra_revenue_per_10k_checkouts
FROM a CROSS JOIN b CROSS JOIN aov;
