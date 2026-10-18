-- =====================================================================
-- 06_funnel_seed.sql  |  Website sessions + event log for funnel / A-B analysis
-- 30,000 sessions (Jan-Mar 2025) -> web_events (visit, product_view,
-- add_to_cart, begin_checkout, purchase)
--
-- Built-in behaviour: mobile converts worse than desktop; Email traffic
-- engages more than Paid Search; checkout "variant B" (new one-page checkout)
-- gets a real uplift over variant A. The analysis has to find it.
-- uniform(0,1) = CONV(LEFT(MD5(key),8),16,10)/4294967296  (see 02_seed_data.sql)
-- =====================================================================
USE shopsphere;

DROP TABLE IF EXISTS web_events;
DROP TABLE IF EXISTS sessions;

CREATE TABLE sessions (
    session_id       INT PRIMARY KEY,
    session_date     DATE NOT NULL,
    device           ENUM('desktop','mobile','tablet') NOT NULL,
    channel          ENUM('Organic','Paid Search','Social','Email','Referral') NOT NULL,
    checkout_variant ENUM('A','B') NOT NULL COMMENT 'A/B test: A = old checkout, B = new one-page checkout',
    INDEX idx_sessions_date (session_date)
);

CREATE TABLE web_events (
    event_id   BIGINT PRIMARY KEY AUTO_INCREMENT,
    session_id INT NOT NULL,
    event_type ENUM('visit','product_view','add_to_cart','begin_checkout','purchase') NOT NULL,
    event_time DATETIME NOT NULL,
    FOREIGN KEY (session_id) REFERENCES sessions(session_id),
    INDEX idx_events_session (session_id),
    INDEX idx_events_type (event_type)
);

-- helper: numbers 1..30000
DROP TABLE IF EXISTS digits;
CREATE TABLE digits (d INT);
INSERT INTO digits VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9);
DROP TABLE IF EXISTS numbers;
CREATE TABLE numbers (n INT PRIMARY KEY);
INSERT INTO numbers
SELECT n FROM (SELECT a.d + 10*b.d + 100*c.d + 1000*e.d + 10000*f.d + 1 AS n
               FROM digits a, digits b, digits c, digits e, digits f) x
WHERE n <= 30000;

INSERT INTO sessions (session_id, session_date, device, channel, checkout_variant)
SELECT n,
       DATE_ADD('2025-01-01', INTERVAL MOD(n,90) DAY),
       CASE WHEN CONV(LEFT(MD5(CONCAT(n,'-dev')),8),16,10)/4294967296 < 0.55 THEN 'mobile'
            WHEN CONV(LEFT(MD5(CONCAT(n,'-dev')),8),16,10)/4294967296 < 0.90 THEN 'desktop'
            ELSE 'tablet' END,
       CASE WHEN CONV(LEFT(MD5(CONCAT(n,'-chn')),8),16,10)/4294967296 < 0.30 THEN 'Organic'
            WHEN CONV(LEFT(MD5(CONCAT(n,'-chn')),8),16,10)/4294967296 < 0.55 THEN 'Paid Search'
            WHEN CONV(LEFT(MD5(CONCAT(n,'-chn')),8),16,10)/4294967296 < 0.75 THEN 'Social'
            WHEN CONV(LEFT(MD5(CONCAT(n,'-chn')),8),16,10)/4294967296 < 0.90 THEN 'Email'
            ELSE 'Referral' END,
       IF(CONV(LEFT(MD5(CONCAT(n,'-var')),8),16,10)/4294967296 < 0.5, 'A', 'B')
FROM numbers;

-- Stage 1: every session starts with a visit
INSERT INTO web_events (session_id, event_type, event_time)
SELECT session_id, 'visit', TIMESTAMP(session_date, SEC_TO_TIME(MOD(session_id * 7919, 80000)))
FROM sessions;

-- Stage 2: visit -> product_view (device and channel matter)
INSERT INTO web_events (session_id, event_type, event_time)
SELECT e.session_id, 'product_view', DATE_ADD(e.event_time, INTERVAL 2 MINUTE)
FROM web_events e JOIN sessions s USING (session_id)
WHERE e.event_type = 'visit'
  AND CONV(LEFT(MD5(CONCAT(e.session_id,'-view')),8),16,10)/4294967296 <
      LEAST(0.95, CASE s.device WHEN 'desktop' THEN 0.62 WHEN 'mobile' THEN 0.48 ELSE 0.55 END
                * CASE s.channel WHEN 'Email' THEN 1.15 WHEN 'Paid Search' THEN 0.90 ELSE 1 END);

-- Stage 3: product_view -> add_to_cart
INSERT INTO web_events (session_id, event_type, event_time)
SELECT e.session_id, 'add_to_cart', DATE_ADD(e.event_time, INTERVAL 3 MINUTE)
FROM web_events e JOIN sessions s USING (session_id)
WHERE e.event_type = 'product_view'
  AND CONV(LEFT(MD5(CONCAT(e.session_id,'-cart')),8),16,10)/4294967296 <
      CASE s.device WHEN 'desktop' THEN 0.32 WHEN 'mobile' THEN 0.24 ELSE 0.28 END;

-- Stage 4: add_to_cart -> begin_checkout
INSERT INTO web_events (session_id, event_type, event_time)
SELECT e.session_id, 'begin_checkout', DATE_ADD(e.event_time, INTERVAL 2 MINUTE)
FROM web_events e JOIN sessions s USING (session_id)
WHERE e.event_type = 'add_to_cart'
  AND CONV(LEFT(MD5(CONCAT(e.session_id,'-chk')),8),16,10)/4294967296 <
      CASE s.device WHEN 'desktop' THEN 0.62 WHEN 'mobile' THEN 0.50 ELSE 0.55 END;

-- Stage 5: begin_checkout -> purchase (variant B really is better; mobile is weaker)
INSERT INTO web_events (session_id, event_type, event_time)
SELECT e.session_id, 'purchase', DATE_ADD(e.event_time, INTERVAL 3 MINUTE)
FROM web_events e JOIN sessions s USING (session_id)
WHERE e.event_type = 'begin_checkout'
  AND CONV(LEFT(MD5(CONCAT(e.session_id,'-buy')),8),16,10)/4294967296 <
      (CASE s.checkout_variant WHEN 'A' THEN 0.58 ELSE 0.66 END)
      - (CASE s.device WHEN 'mobile' THEN 0.05 ELSE 0 END);

DROP TABLE numbers;
DROP TABLE digits;

-- One row per session with a 0/1 flag for each funnel step reached
CREATE OR REPLACE VIEW v_session_funnel AS
SELECT s.session_id, s.session_date, s.device, s.channel, s.checkout_variant,
       1                                              AS visited,
       MAX(e.event_type = 'product_view')             AS viewed,
       MAX(e.event_type = 'add_to_cart')              AS carted,
       MAX(e.event_type = 'begin_checkout')           AS checkout,
       MAX(e.event_type = 'purchase')                 AS purchased
FROM sessions s
LEFT JOIN web_events e ON e.session_id = s.session_id
GROUP BY s.session_id, s.session_date, s.device, s.channel, s.checkout_variant;
