-- =====================================================================
-- 04_analysis_queries.sql  |  Business questions answered with SQL
-- Skills: JOINs, CTEs, window functions, cohorts, RFM, Pareto
-- =====================================================================
USE shopsphere;

-- Q1. Headline KPIs ---------------------------------------------------
SELECT COUNT(DISTINCT order_id)                         AS completed_orders,
       COUNT(DISTINCT customer_id)                      AS active_customers,
       ROUND(SUM(revenue), 2)                           AS total_revenue,
       ROUND(SUM(revenue - cost) / SUM(revenue) * 100, 1) AS gross_margin_pct,
       ROUND(SUM(revenue) / COUNT(DISTINCT order_id), 2)  AS avg_order_value
FROM v_order_lines
WHERE status = 'completed';

-- Q2. Monthly revenue with month-over-month growth (LAG) --------------
SELECT month_start, revenue,
       LAG(revenue) OVER (ORDER BY month_start) AS prev_month,
       ROUND((revenue - LAG(revenue) OVER (ORDER BY month_start))
             / LAG(revenue) OVER (ORDER BY month_start) * 100, 1) AS mom_growth_pct
FROM v_monthly_revenue
ORDER BY month_start;

-- Q3. Running (cumulative) revenue by month, reset each year ----------
SELECT month_start, revenue,
       SUM(revenue) OVER (PARTITION BY YEAR(month_start)
                          ORDER BY month_start) AS ytd_revenue
FROM v_monthly_revenue
ORDER BY month_start;

-- Q4. Category revenue, profit margin and share of total --------------
SELECT category_name,
       ROUND(SUM(revenue), 2)                                   AS revenue,
       ROUND(SUM(revenue - cost) / SUM(revenue) * 100, 1)       AS margin_pct,
       ROUND(SUM(revenue) / SUM(SUM(revenue)) OVER () * 100, 1) AS revenue_share_pct
FROM v_order_lines
WHERE status = 'completed'
GROUP BY category_name
ORDER BY revenue DESC;

-- Q5. Top 3 products inside each category (RANK + CTE) ----------------
WITH product_rev AS (
    SELECT category_name, product_name, SUM(revenue) AS revenue
    FROM v_order_lines
    WHERE status = 'completed'
    GROUP BY category_name, product_name
), ranked AS (
    SELECT *, RANK() OVER (PARTITION BY category_name ORDER BY revenue DESC) AS rnk
    FROM product_rev
)
SELECT category_name, product_name, ROUND(revenue,2) AS revenue, rnk
FROM ranked
WHERE rnk <= 3
ORDER BY category_name, rnk;

-- Q6. Acquisition channel performance ---------------------------------
SELECT channel,
       COUNT(DISTINCT customer_id)                          AS customers,
       ROUND(SUM(revenue), 2)                               AS revenue,
       ROUND(SUM(revenue) / COUNT(DISTINCT customer_id), 2) AS revenue_per_customer
FROM v_order_lines
WHERE status = 'completed'
GROUP BY channel
ORDER BY revenue_per_customer DESC;

-- Q7. Repeat-purchase rate --------------------------------------------
WITH per_customer AS (
    SELECT customer_id, COUNT(DISTINCT order_id) AS orders
    FROM orders WHERE status = 'completed'
    GROUP BY customer_id
)
SELECT COUNT(*)                                             AS buyers,
       SUM(orders > 1)                                      AS repeat_buyers,
       ROUND(SUM(orders > 1) / COUNT(*) * 100, 1)           AS repeat_rate_pct
FROM per_customer;

-- Q8. RFM segmentation (NTILE) ----------------------------------------
WITH rfm_base AS (
    SELECT customer_id,
           DATEDIFF('2025-10-31', MAX(order_date)) AS recency_days,
           COUNT(DISTINCT order_id)                AS frequency,
           SUM(revenue)                            AS monetary
    FROM v_order_lines
    WHERE status = 'completed'
    GROUP BY customer_id
), rfm_scored AS (
    SELECT *,
           NTILE(4) OVER (ORDER BY recency_days DESC) AS r,
           NTILE(4) OVER (ORDER BY frequency)         AS f,
           NTILE(4) OVER (ORDER BY monetary)          AS m
    FROM rfm_base
)
SELECT CASE WHEN r >= 3 AND f >= 3 AND m >= 3 THEN 'Champions'
            WHEN r >= 3 AND f >= 2             THEN 'Loyal'
            WHEN r <= 2 AND m >= 3             THEN 'At Risk (high value)'
            WHEN r = 1                         THEN 'Lost'
            ELSE 'Needs Attention' END AS segment,
       COUNT(*)                        AS customers,
       ROUND(AVG(monetary), 2)         AS avg_spend
FROM rfm_scored
GROUP BY segment
ORDER BY avg_spend DESC;

-- Q9. Monthly cohort retention (signup month vs. months since) -------
WITH first_order AS (
    SELECT customer_id,
           DATE_FORMAT(MIN(order_date), '%Y-%m-01') AS cohort_month
    FROM orders WHERE status = 'completed'
    GROUP BY customer_id
), activity AS (
    SELECT DISTINCT o.customer_id, f.cohort_month,
           TIMESTAMPDIFF(MONTH, f.cohort_month, o.order_date) AS month_index
    FROM orders o
    JOIN first_order f USING (customer_id)
    WHERE o.status = 'completed'
), cohort_size AS (
    SELECT cohort_month, COUNT(*) AS size FROM first_order GROUP BY cohort_month
)
SELECT a.cohort_month, cs.size AS cohort_size, a.month_index,
       COUNT(DISTINCT a.customer_id) AS active,
       ROUND(COUNT(DISTINCT a.customer_id) / cs.size * 100, 1) AS retention_pct
FROM activity a
JOIN cohort_size cs USING (cohort_month)
WHERE a.month_index BETWEEN 0 AND 6
GROUP BY a.cohort_month, cs.size, a.month_index
ORDER BY a.cohort_month, a.month_index;

-- Q10. Pareto: what share of customers drive 80% of revenue? ---------
WITH cust AS (
    SELECT customer_id, SUM(revenue) AS revenue
    FROM v_order_lines WHERE status = 'completed'
    GROUP BY customer_id
), cum AS (
    SELECT customer_id, revenue,
           SUM(revenue) OVER (ORDER BY revenue DESC) / SUM(revenue) OVER () AS cum_share,
           ROW_NUMBER() OVER (ORDER BY revenue DESC) AS rn,
           COUNT(*) OVER () AS total
    FROM cust
)
SELECT MAX(rn) AS customers_for_80pct_revenue,
       ROUND(MAX(rn) / MAX(total) * 100, 1) AS pct_of_customers
FROM cum
WHERE cum_share <= 0.80;

-- Q11. Return & cancellation rate by category ------------------------
SELECT category_name,
       COUNT(DISTINCT order_id)                                        AS orders,
       ROUND(COUNT(DISTINCT CASE WHEN status='returned'  THEN order_id END)
             / COUNT(DISTINCT order_id) * 100, 1)                      AS return_rate_pct,
       ROUND(COUNT(DISTINCT CASE WHEN status='cancelled' THEN order_id END)
             / COUNT(DISTINCT order_id) * 100, 1)                      AS cancel_rate_pct
FROM v_order_lines
GROUP BY category_name
ORDER BY return_rate_pct DESC;

-- Q12. Day-of-week demand pattern ------------------------------------
SELECT DAYNAME(order_date) AS weekday,
       COUNT(DISTINCT order_id) AS orders,
       ROUND(SUM(revenue), 2)   AS revenue
FROM v_order_lines
WHERE status = 'completed'
GROUP BY weekday, DAYOFWEEK(order_date)
ORDER BY DAYOFWEEK(order_date);
