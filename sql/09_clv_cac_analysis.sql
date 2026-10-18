-- =====================================================================
-- 09_clv_cac_analysis.sql  |  Which marketing channels pay for themselves?
-- Cohort studied: customers who signed up Jan-Oct 2024, so every one of
-- them has a full 12 months of history before the data ends (2025-10-31).
-- LTV is measured on GROSS PROFIT (revenue - product cost), not revenue.
-- Skills: cohort design, LEFT JOIN with time window, cumulative windows,
--         unit economics (CAC, LTV:CAC, payback period)
-- =====================================================================
USE shopsphere;

-- Reusable view: 12-month gross profit per customer in the study cohort
CREATE OR REPLACE VIEW v_customer_12m_value AS
SELECT c.customer_id, c.channel, c.signup_date,
       COALESCE(SUM(v.revenue), 0)         AS revenue_12m,
       COALESCE(SUM(v.revenue - v.cost), 0) AS gross_profit_12m,
       COUNT(DISTINCT v.order_id)          AS orders_12m
FROM customers c
LEFT JOIN v_order_lines v
       ON v.customer_id = c.customer_id
      AND v.status = 'completed'
      AND v.order_date < DATE_ADD(c.signup_date, INTERVAL 365 DAY)
WHERE c.signup_date BETWEEN '2024-01-01' AND '2024-10-31'
GROUP BY c.customer_id, c.channel, c.signup_date;

-- Q1. Unit economics per channel: CAC, 12-month LTV, LTV:CAC
WITH ltv AS (
    SELECT channel,
           COUNT(*)                          AS customers,
           ROUND(AVG(orders_12m), 2)         AS orders_per_customer,
           ROUND(AVG(revenue_12m), 2)        AS revenue_per_customer,
           ROUND(AVG(gross_profit_12m), 2)   AS ltv_12m
    FROM v_customer_12m_value
    GROUP BY channel
), spend AS (
    SELECT channel, SUM(spend) AS total_spend
    FROM marketing_spend
    WHERE month_start BETWEEN '2024-01-01' AND '2024-10-01'
    GROUP BY channel
)
SELECT l.channel, l.customers, l.orders_per_customer, l.revenue_per_customer, l.ltv_12m,
       ROUND(s.total_spend / l.customers, 2)             AS cac,
       ROUND(l.ltv_12m / (s.total_spend / l.customers), 2) AS ltv_to_cac,
       ROUND(l.ltv_12m - s.total_spend / l.customers, 2) AS net_profit_per_customer
FROM ltv l
JOIN spend s USING (channel)
ORDER BY ltv_to_cac DESC;

-- Q2. Payback period: in which month does cumulative gross profit per
--     customer first exceed what it cost to acquire them?
WITH cohort_size AS (
    SELECT channel, COUNT(*) AS customers FROM v_customer_12m_value GROUP BY channel
), cac AS (
    SELECT m.channel, SUM(m.spend) / cs.customers AS cac
    FROM marketing_spend m
    JOIN cohort_size cs USING (channel)
    WHERE m.month_start BETWEEN '2024-01-01' AND '2024-10-01'
    GROUP BY m.channel, cs.customers
), months AS (
    SELECT 0 AS m UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
    UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8
    UNION ALL SELECT 9 UNION ALL SELECT 10 UNION ALL SELECT 11
), monthly_gp AS (
    SELECT c.channel, TIMESTAMPDIFF(MONTH, c.signup_date, v.order_date) AS m,
           SUM(v.revenue - v.cost) AS gp
    FROM customers c
    JOIN v_order_lines v ON v.customer_id = c.customer_id AND v.status = 'completed'
    WHERE c.signup_date BETWEEN '2024-01-01' AND '2024-10-31'
      AND v.order_date < DATE_ADD(c.signup_date, INTERVAL 365 DAY)
    GROUP BY c.channel, m
), grid AS (
    SELECT cs.channel, cs.customers, mo.m, COALESCE(g.gp, 0) AS gp
    FROM cohort_size cs
    CROSS JOIN months mo
    LEFT JOIN monthly_gp g ON g.channel = cs.channel AND g.m = mo.m
), cumulative AS (
    SELECT channel, customers, m,
           SUM(gp) OVER (PARTITION BY channel ORDER BY m) / customers AS cum_gp_per_customer
    FROM grid
)
SELECT cu.channel,
       ROUND(ca.cac, 2)                                           AS cac,
       ROUND(MAX(CASE WHEN cu.m = 11 THEN cu.cum_gp_per_customer END), 2) AS gp_per_customer_12m,
       COALESCE(CAST(MIN(CASE WHEN cu.cum_gp_per_customer >= ca.cac THEN cu.m + 1 END) AS CHAR),
                'not within 12 months')                           AS payback_month
FROM cumulative cu
JOIN cac ca USING (channel)
GROUP BY cu.channel, ca.cac
ORDER BY ca.cac;

-- Q3. Budget view: share of spend vs share of profit created
WITH ltv AS (
    SELECT channel, SUM(gross_profit_12m) AS gross_profit
    FROM v_customer_12m_value GROUP BY channel
), spend AS (
    SELECT channel, SUM(spend) AS total_spend
    FROM marketing_spend
    WHERE month_start BETWEEN '2024-01-01' AND '2024-10-01'
    GROUP BY channel
)
SELECT l.channel,
       ROUND(s.total_spend, 0)                                       AS spend,
       ROUND(100 * s.total_spend / SUM(s.total_spend) OVER (), 1)    AS pct_of_spend,
       ROUND(l.gross_profit, 0)                                      AS gross_profit,
       ROUND(100 * l.gross_profit / SUM(l.gross_profit) OVER (), 1)  AS pct_of_profit,
       ROUND(l.gross_profit - s.total_spend, 0)                      AS net_return
FROM ltv l JOIN spend s USING (channel)
ORDER BY net_return DESC;

-- Q4. THE RECOMMENDATION: classify each channel by LTV:CAC
WITH ltv AS (
    SELECT channel, AVG(gross_profit_12m) AS ltv_12m FROM v_customer_12m_value GROUP BY channel
), cac AS (
    SELECT m.channel, SUM(m.spend) / cs.customers AS cac
    FROM marketing_spend m
    JOIN (SELECT channel, COUNT(*) AS customers FROM v_customer_12m_value GROUP BY channel) cs USING (channel)
    WHERE m.month_start BETWEEN '2024-01-01' AND '2024-10-01'
    GROUP BY m.channel, cs.customers
)
SELECT l.channel,
       ROUND(l.ltv_12m / c.cac, 2) AS ltv_to_cac,
       CASE WHEN l.ltv_12m / c.cac >= 3 THEN 'SCALE: shift more budget here'
            WHEN l.ltv_12m / c.cac >= 1 THEN 'OPTIMIZE: profitable but thin; lower CAC or raise repeat rate'
            ELSE 'FIX OR CUT: customers never earn back acquisition cost' END AS recommendation
FROM ltv l JOIN cac c USING (channel)
ORDER BY ltv_to_cac DESC;
