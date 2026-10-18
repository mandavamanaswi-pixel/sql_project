-- =====================================================================
-- 03_views.sql  |  Reusable analytics layer
-- =====================================================================
USE shopsphere;

-- One row per order line with revenue, cost and profit.
-- Revenue only counts completed orders.
CREATE OR REPLACE VIEW v_order_lines AS
SELECT  o.order_id, o.customer_id, o.order_date, o.status,
        c.channel, c.city, c.signup_date,
        p.product_id, p.product_name, cat.category_name,
        oi.quantity,
        ROUND(oi.quantity * oi.unit_price * (1 - oi.discount_pct/100), 2) AS revenue,
        ROUND(oi.quantity * p.unit_cost, 2)                               AS cost
FROM order_items oi
JOIN orders     o   ON o.order_id    = oi.order_id
JOIN customers  c   ON c.customer_id = o.customer_id
JOIN products   p   ON p.product_id  = oi.product_id
JOIN categories cat ON cat.category_id = p.category_id;

-- Monthly revenue of completed orders
CREATE OR REPLACE VIEW v_monthly_revenue AS
SELECT DATE_FORMAT(order_date, '%Y-%m-01') AS month_start,
       COUNT(DISTINCT order_id)            AS orders,
       SUM(revenue)                        AS revenue,
       SUM(revenue - cost)                 AS gross_profit
FROM v_order_lines
WHERE status = 'completed'
GROUP BY 1;
