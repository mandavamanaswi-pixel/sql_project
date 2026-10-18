-- =====================================================================
-- 08_marketing_seed.sql  |  Monthly marketing spend by channel (synthetic)
-- Spend = new customers acquired x assumed cost-per-acquisition for the
-- channel x a +/-15% monthly noise factor. The CAC assumptions below are
-- made-up inputs (documented in the README); the analysis then measures
-- whether each channel's customers actually earn that money back.
-- =====================================================================
USE shopsphere;

DROP TABLE IF EXISTS marketing_spend;
CREATE TABLE marketing_spend (
    spend_id    INT PRIMARY KEY AUTO_INCREMENT,
    month_start DATE NOT NULL,
    channel     ENUM('Organic','Paid Search','Social','Email','Referral') NOT NULL,
    spend       DECIMAL(12,2) NOT NULL CHECK (spend >= 0),
    UNIQUE KEY uq_month_channel (month_start, channel)
);

INSERT INTO marketing_spend (month_start, channel, spend)
SELECT month_start, channel,
       ROUND(new_customers
             * CASE channel WHEN 'Organic'     THEN 30     -- content / SEO
                            WHEN 'Paid Search' THEN 240    -- ad auctions
                            WHEN 'Social'      THEN 150    -- paid social
                            WHEN 'Email'       THEN 45     -- tooling + list growth
                            ELSE 90 END                    -- referral rewards
             * (0.85 + 0.30 * CONV(LEFT(MD5(CONCAT(month_start, channel)),8),16,10) / 4294967296), 2)
FROM (SELECT DATE_FORMAT(signup_date, '%Y-%m-01') AS month_start, channel, COUNT(*) AS new_customers
      FROM customers
      GROUP BY DATE_FORMAT(signup_date, '%Y-%m-01'), channel) t;
