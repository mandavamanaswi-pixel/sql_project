-- =====================================================================
-- 02_seed_data.sql  |  Deterministic synthetic data (no CSVs needed)
-- 500 customers, 30 products, ~1,500 orders, ~3,000 order lines
--
-- Randomness: MySQL's RAND(seed) is correlated for consecutive seeds, so
-- every "random" number here is a uniform(0,1) value derived from an MD5
-- hash:  CONV(LEFT(MD5(key),8),16,10) / 4294967296
-- -> reproducible, evenly distributed, identical on every machine.
--
-- Behaviour baked into the data (so the analysis has something to find):
--   * 10% of signups never buy
--   * Repeat orders follow a rhythm: ~60 days (1st->2nd), ~40 days after
--   * Organic / Referral customers reorder more than Paid Search customers
-- =====================================================================
USE shopsphere;

-- Helper table of 25,000 numbers, each with 4 hash-based uniform randoms
DROP TABLE IF EXISTS digits;
CREATE TABLE digits (d INT);
INSERT INTO digits VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9);

DROP TABLE IF EXISTS numbers;
CREATE TABLE numbers (n INT PRIMARY KEY, u1 DOUBLE, u2 DOUBLE, u3 DOUBLE, u4 DOUBLE);
INSERT INTO numbers
SELECT n,
       CONV(LEFT(MD5(CONCAT(n,'-a')),8),16,10) / 4294967296,
       CONV(LEFT(MD5(CONCAT(n,'-b')),8),16,10) / 4294967296,
       CONV(LEFT(MD5(CONCAT(n,'-c')),8),16,10) / 4294967296,
       CONV(LEFT(MD5(CONCAT(n,'-d')),8),16,10) / 4294967296
FROM (SELECT a.d + 10*b.d + 100*c.d + 1000*e.d + 10000*f.d + 1 AS n
      FROM digits a, digits b, digits c, digits e, digits f) x
WHERE n <= 25000;

INSERT INTO categories (category_name) VALUES
 ('Electronics'),('Home & Kitchen'),('Fashion'),('Sports'),('Beauty'),('Books');

INSERT INTO products (product_name, category_id, unit_price, unit_cost)
SELECT CONCAT('Product ', LPAD(n,2,'0')),
       MOD(n,6) + 1,
       @p := 10 + MOD(n*37, 190),
       ROUND(@p * (0.45 + MOD(n,5)*0.06), 2)
FROM numbers WHERE n <= 30;

-- Customers: signups spread over Jan 2024 - Feb 2025
INSERT INTO customers (first_name, last_name, email, city, signup_date, channel)
SELECT ELT(MOD(n,10)+1,'Ava','Liam','Noah','Emma','Olivia','Ethan','Mia','Lucas','Zoe','Aarav'),
       ELT(MOD(n*3,10)+1,'Smith','Patel','Garcia','Khan','Brown','Lee','Wilson','Nguyen','Davis','Singh'),
       CONCAT('customer', n, '@example.com'),
       ELT(1 + FLOOR(u3 * 8), 'New York','Chicago','Austin','Seattle','Denver','Boston','Miami','Phoenix'),
       DATE_ADD('2024-01-01', INTERVAL FLOOR(u1 * 425) DAY),
       ELT(1 + FLOOR(u2 * 5), 'Organic','Paid Search','Social','Email','Referral')
FROM numbers WHERE n <= 500;

-- Orders: each buyer gets a number of orders (channel-dependent), spaced by
-- an exponential-style gap; running total of gaps gives each order date.
INSERT INTO orders (customer_id, order_date, status)
WITH cust AS (
    SELECT c.customer_id, c.signup_date,
           CASE WHEN r.u1 < 0.10 THEN 0
                ELSE 1 + FLOOR(-LN(1 - r.u3) * CASE c.channel
                         WHEN 'Organic' THEN 4.0 WHEN 'Referral' THEN 3.6
                         WHEN 'Email' THEN 3.2 WHEN 'Social' THEN 2.4 ELSE 1.6 END)
           END AS n_orders,
           FLOOR(-LN(1 - r.u4) * 15) AS first_lag_days
    FROM customers c
    JOIN numbers r ON r.n = 5000 + c.customer_id      -- independent stream from the customers insert
), plan AS (
    SELECT c.customer_id, c.signup_date, c.first_lag_days, k.n AS j,
           CASE WHEN k.n = 1 THEN 0
                ELSE 7 + FLOOR(-LN(1 - g.u1) * CASE WHEN k.n = 2 THEN 60 ELSE 40 END)
           END AS gap_days,
           g.u2 AS u_status
    FROM cust c
    JOIN numbers k ON k.n <= LEAST(c.n_orders, 40)
    JOIN numbers g ON g.n = 1000 + c.customer_id * 40 + k.n
), dated AS (
    SELECT customer_id, u_status,
           DATE_ADD(signup_date,
                    INTERVAL first_lag_days + SUM(gap_days) OVER (PARTITION BY customer_id ORDER BY j) DAY) AS order_date
    FROM plan
)
SELECT customer_id, order_date,
       CASE WHEN u_status < 0.05 THEN 'cancelled'
            WHEN u_status < 0.12 THEN 'returned'
            ELSE 'completed' END
FROM dated
WHERE order_date <= '2025-10-31'
ORDER BY order_date, customer_id;      -- so order_id increases with time

-- Order lines: every order gets 1 line; 2/3 get a 2nd line; 1/3 get a 3rd.
INSERT INTO order_items (order_id, product_id, quantity, unit_price, discount_pct)
SELECT o.order_id, p.product_id,
       1 + FLOOR(r.u2 * 4),
       p.unit_price,
       ELT(1 + FLOOR(r.u3 * 4), 0, 5, 10, 15)
FROM orders o
JOIN (SELECT 1 AS k UNION ALL SELECT 2 UNION ALL SELECT 3) k
  ON k.k = 1 OR (k.k = 2 AND MOD(o.order_id,3) <> 0) OR (k.k = 3 AND MOD(o.order_id,3) = 1)
JOIN numbers r ON r.n = 10000 + o.order_id * 3 + k.k
JOIN products p ON p.product_id = 1 + FLOOR(30 * POW(r.u1, 1.3));   -- popular products sell more

DROP TABLE numbers;
DROP TABLE digits;
