-- The 8 business questions, answered against the star schema.
-- Run after sql/gold/03_product_bridge.sql (question 7 needs the bridge).

-- Q1. Which manufacturers are making the highest payments to physicians?
SELECT m.manufacturer_name, m.manufacturer_state,
       sum(f.total_payment_us_dollars) AS total_payment_usd,
       count(*)                        AS payment_records,
       count(DISTINCT f.recipient_key) AS distinct_physicians
FROM gold.fct_payments f
JOIN gold.dim_manufacturer   m  ON m.manufacturer_key    = f.manufacturer_key
JOIN gold.lkp_recipient_type rt ON rt.recipient_type_key = f.recipient_type_key
WHERE rt.recipient_type = 'Covered Recipient Physician'
GROUP BY m.manufacturer_name, m.manufacturer_state
ORDER BY total_payment_usd DESC
LIMIT 20;


-- Q2. Which physicians received the highest total payments?
SELECT r.recipient_npi, r.full_name, r.specialty,
       sum(f.total_payment_us_dollars)                    AS total_payment_usd,
       sum(f.number_of_payments_included_in_total_amount) AS discrete_payments,
       count(DISTINCT f.manufacturer_key)                 AS distinct_manufacturers
FROM gold.fct_payments f
JOIN gold.dim_recipient      r  ON r.recipient_key       = f.recipient_key
JOIN gold.lkp_recipient_type rt ON rt.recipient_type_key = f.recipient_type_key
WHERE rt.recipient_type = 'Covered Recipient Physician' AND f.recipient_key > 0
GROUP BY r.recipient_key, r.recipient_npi, r.full_name, r.specialty
ORDER BY total_payment_usd DESC
LIMIT 20;


-- Q3. What type of payment is most common?
SELECT n.payment_nature,
       count(*)                                            AS payment_records,
       sum(f.number_of_payments_included_in_total_amount)  AS discrete_payments,
       sum(f.total_payment_us_dollars)                     AS total_payment_usd,
       round(avg(f.total_payment_us_dollars)::numeric, 2)  AS avg_payment_usd
FROM gold.fct_payments f
JOIN gold.dim_payment_nature n ON n.payment_nature_key = f.payment_nature_key
GROUP BY n.payment_nature
ORDER BY payment_records DESC;


-- Q4. Which states / cities have the highest payment activity?
-- The location is the physician's, or the teaching hospital's on hospital payments.

-- Q4a. By state
SELECT coalesce(r.state_code, h.state_code) AS state_code,
       count(*)                             AS payment_records,
       sum(f.total_payment_us_dollars)      AS total_payment_usd
FROM gold.fct_payments f
JOIN gold.dim_recipient         r ON r.recipient_key         = f.recipient_key
JOIN gold.dim_teaching_hospital h ON h.teaching_hospital_key = f.teaching_hospital_key
WHERE coalesce(r.state_code, h.state_code) IS NOT NULL
GROUP BY coalesce(r.state_code, h.state_code)
ORDER BY total_payment_usd DESC
LIMIT 20;

-- Q4b. By city
SELECT coalesce(r.state_code, h.state_code) AS state_code,
       coalesce(r.city, h.city)             AS city,
       count(*)                             AS payment_records,
       sum(f.total_payment_us_dollars)      AS total_payment_usd
FROM gold.fct_payments f
JOIN gold.dim_recipient         r ON r.recipient_key         = f.recipient_key
JOIN gold.dim_teaching_hospital h ON h.teaching_hospital_key = f.teaching_hospital_key
WHERE coalesce(r.city, h.city) IS NOT NULL
GROUP BY coalesce(r.state_code, h.state_code), coalesce(r.city, h.city)
ORDER BY total_payment_usd DESC
LIMIT 20;


-- Q5. What is the trend of payments over time?
SELECT d.year_number, d.year_quarter, d.year_month,
       count(*)                        AS payment_records,
       sum(f.total_payment_us_dollars) AS total_payment_usd
FROM gold.fct_payments f
JOIN gold.dim_date d ON d.date_key = f.date_key
WHERE f.date_key <> -1
GROUP BY d.year_number, d.year_quarter, d.year_month
ORDER BY d.year_month;


-- Q6. Which medical specialties receive the highest payments?
SELECT r.specialty,
       count(DISTINCT r.recipient_key) AS physicians,
       sum(f.total_payment_us_dollars) AS total_payment_usd,
       round((sum(f.total_payment_us_dollars) / count(DISTINCT r.recipient_key))::numeric, 2) AS avg_usd_per_physician
FROM gold.fct_payments f
JOIN gold.dim_recipient r ON r.recipient_key = f.recipient_key
WHERE f.recipient_key > 0 AND r.specialty IS NOT NULL
GROUP BY r.specialty
ORDER BY total_payment_usd DESC
LIMIT 25;


-- Q7. Which drugs / medical products are linked with the highest payments?
-- Goes through the bridge: each payment is split across its products (product_share = 1/n),
-- so nothing is counted twice.
SELECT p.product_name, p.product_type, p.product_category,
       count(*)                                          AS payment_records,
       sum(f.total_payment_us_dollars * b.product_share) AS product_payment_usd
FROM gold.fct_payments f
JOIN gold.bridge_payment_product b ON b.payment_key = f.payment_key
JOIN gold.dim_product            p ON p.product_key = b.product_key
WHERE b.product_key <> -1
GROUP BY p.product_name, p.product_type, p.product_category
ORDER BY product_payment_usd DESC
LIMIT 25;


-- Q8. Which payment categories are increasing or decreasing over time?
-- The data covers one program year (2025), so compare the first quarter with the last.
WITH quarterly AS (
    SELECT n.payment_nature,
           sum(f.total_payment_us_dollars) FILTER (WHERE d.quarter_number = 1) AS q1_usd,
           sum(f.total_payment_us_dollars) FILTER (WHERE d.quarter_number = 4) AS q4_usd,
           count(*)                        FILTER (WHERE d.quarter_number = 1) AS q1_records,
           count(*)                        FILTER (WHERE d.quarter_number = 4) AS q4_records
    FROM gold.fct_payments f
    JOIN gold.dim_payment_nature n ON n.payment_nature_key = f.payment_nature_key
    JOIN gold.dim_date d           ON d.date_key           = f.date_key
    WHERE f.date_key <> -1
    GROUP BY n.payment_nature
)
SELECT payment_nature, q1_records, q4_records,
       round((100.0 * (q4_records - q1_records) / nullif(q1_records, 0))::numeric, 1) AS records_change_pct,
       round((100.0 * (q4_usd - q1_usd)         / nullif(q1_usd, 0))::numeric, 1)     AS amount_change_pct,
       CASE WHEN q4_records > q1_records THEN 'Increasing'
            WHEN q4_records < q1_records THEN 'Decreasing'
            ELSE 'Flat' END                                                            AS direction
FROM quarterly
ORDER BY records_change_pct DESC NULLS LAST;
