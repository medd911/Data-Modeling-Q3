-- Load the dimensions, the fact and the product bridge from the staging tables,
-- then add the foreign keys and indexes. Run after 01_create_gold_tables.sql and 02_stage_payments.sql.
-- (To reload, start again from 01: it recreates the empty tables.)

SET work_mem = '1GB';

-- dim_date
INSERT INTO gold.dim_date
SELECT TO_CHAR(d, 'YYYYMMDD')::integer, d::date,
       EXTRACT(day FROM d), EXTRACT(month FROM d), TRIM(TO_CHAR(d, 'Month')),
       EXTRACT(quarter FROM d), 'Q' || EXTRACT(quarter FROM d),
       EXTRACT(year FROM d), TO_CHAR(d, 'YYYY-MM'), TO_CHAR(d, 'YYYY') || '-Q' || EXTRACT(quarter FROM d),
       EXTRACT(isodow FROM d), TRIM(TO_CHAR(d, 'Day')), EXTRACT(isodow FROM d) IN (6, 7)
FROM generate_series(DATE '2013-01-01', DATE '2030-12-31', INTERVAL '1 day') AS g(d);

INSERT INTO gold.dim_date (date_key, month_name, quarter_name, year_month, year_quarter, day_name)
VALUES (-1, 'Unknown', 'Unknown', 'Unknown', 'Unknown', 'Unknown');

-- dim_manufacturer (the latest published record wins)
INSERT INTO gold.dim_manufacturer (manufacturer_key, manufacturer_name) VALUES (-1, 'Unknown');

INSERT INTO gold.dim_manufacturer (manufacturer_id, manufacturer_name, manufacturer_state, manufacturer_country)
SELECT DISTINCT ON (manufacturer_id) manufacturer_id, manufacturer_name, manufacturer_state, manufacturer_country
FROM gold.stg_payments
WHERE manufacturer_id IS NOT NULL
ORDER BY manufacturer_id, publication_date DESC;

-- dim_recipient
INSERT INTO gold.dim_recipient (recipient_key, full_name, recipient_type) VALUES
    (-1, 'Unknown', 'Unknown'),
    (-2, 'Not Applicable (teaching hospital payment)', 'Not Applicable');

INSERT INTO gold.dim_recipient (recipient_profile_id, recipient_npi, full_name, recipient_type, primary_type,
                                specialty, address_line1, city, state_code, zip_code, country)
SELECT DISTINCT ON (recipient_profile_id)
       recipient_profile_id, recipient_npi, full_name, recipient_type, primary_type,
       specialty, address_line1, city, state_code, zip_code, country
FROM gold.stg_payments
WHERE recipient_profile_id IS NOT NULL
ORDER BY recipient_profile_id, publication_date DESC;

-- dim_teaching_hospital
INSERT INTO gold.dim_teaching_hospital (teaching_hospital_key, hospital_name) VALUES
    (-1, 'Unknown'),
    (-2, 'Not Applicable (physician payment)');

INSERT INTO gold.dim_teaching_hospital (teaching_hospital_id, hospital_name, hospital_ccn, address_line1, city, state_code, zip_code)
SELECT DISTINCT ON (teaching_hospital_id)
       teaching_hospital_id, hospital_name, hospital_ccn, address_line1, city, state_code, zip_code
FROM gold.stg_payments
WHERE teaching_hospital_id IS NOT NULL
ORDER BY teaching_hospital_id, publication_date DESC;

-- Small dimensions: one row per distinct value ('N/A' = payments with no travel)
INSERT INTO gold.dim_payment_nature (payment_nature) SELECT DISTINCT payment_nature FROM gold.stg_payments;
INSERT INTO gold.dim_payment_form (payment_form)     SELECT DISTINCT payment_form   FROM gold.stg_payments;
INSERT INTO gold.lkp_recipient_type (recipient_type) SELECT DISTINCT recipient_type FROM gold.stg_payments;

INSERT INTO gold.dim_travel (travel_city, travel_state, travel_country)
SELECT DISTINCT travel_city, travel_state, travel_country FROM gold.stg_payments;

INSERT INTO gold.dim_payment_flags (change_type, physician_ownership, third_party_payment, charity,
                                    third_party_is_recipient, delay_in_publication, dispute_status, related_product)
SELECT DISTINCT change_type, physician_ownership, third_party_payment, charity,
                third_party_is_recipient, delay_in_publication, dispute_status, related_product
FROM gold.stg_payments;

-- dim_product: one row per product type and name
INSERT INTO gold.dim_product (product_key, product_name, product_type) VALUES (-1, 'No Related Product', 'N/A');

INSERT INTO gold.dim_product (product_name, product_type, product_category, ndc, pdi)
SELECT DISTINCT ON (product_type, product_name) product_name, product_type, product_category, ndc, pdi
FROM gold.stg_payment_products
ORDER BY product_type, product_name, record_id DESC;

ANALYZE gold.dim_recipient;
ANALYZE gold.dim_teaching_hospital;
ANALYZE gold.dim_manufacturer;
ANALYZE gold.dim_product;

-- fact
INSERT INTO gold.fct_payments (record_id, date_key, manufacturer_key, recipient_key, teaching_hospital_key,
                               recipient_type_key, payment_nature_key, payment_form_key, travel_key, payment_flags_key,
                               total_payment_us_dollars, number_of_payments_included_in_total_amount)
SELECT s.record_id,
       COALESCE(d.date_key, -1),
       COALESCE(m.manufacturer_key, -1),
       COALESCE(r.recipient_key,         CASE WHEN s.teaching_hospital_id IS NOT NULL THEN -2 ELSE -1 END),
       COALESCE(h.teaching_hospital_key, CASE WHEN s.recipient_profile_id IS NOT NULL THEN -2 ELSE -1 END),
       rt.recipient_type_key, n.payment_nature_key, f.payment_form_key, t.travel_key, fl.payment_flags_key,
       COALESCE(s.total_payment_us_dollars, 0),
       COALESCE(s.number_of_payments, 1)
FROM gold.stg_payments s
LEFT JOIN gold.dim_date               d ON d.date_key = TO_CHAR(s.payment_date, 'YYYYMMDD')::integer
LEFT JOIN gold.dim_manufacturer       m ON m.manufacturer_id = s.manufacturer_id
LEFT JOIN gold.dim_recipient          r ON r.recipient_profile_id = s.recipient_profile_id
LEFT JOIN gold.dim_teaching_hospital  h ON h.teaching_hospital_id = s.teaching_hospital_id
JOIN gold.lkp_recipient_type rt ON rt.recipient_type = s.recipient_type
JOIN gold.dim_payment_nature n  ON n.payment_nature  = s.payment_nature
JOIN gold.dim_payment_form   f  ON f.payment_form    = s.payment_form
JOIN gold.dim_travel         t  ON t.travel_city = s.travel_city AND t.travel_state = s.travel_state
                               AND t.travel_country = s.travel_country
JOIN gold.dim_payment_flags  fl ON fl.change_type = s.change_type AND fl.physician_ownership = s.physician_ownership
                               AND fl.third_party_payment = s.third_party_payment AND fl.charity = s.charity
                               AND fl.third_party_is_recipient = s.third_party_is_recipient
                               AND fl.delay_in_publication = s.delay_in_publication
                               AND fl.dispute_status = s.dispute_status AND fl.related_product = s.related_product;

ANALYZE gold.fct_payments;

-- bridge: each payment's amount is split evenly across its products (product_share = 1 / products on the payment)
INSERT INTO gold.bridge_payment_product (payment_key, product_slot, product_key, product_share)
SELECT f.payment_key, p.slot, d.product_key, 1.0 / COUNT(*) OVER (PARTITION BY p.record_id)
FROM gold.stg_payment_products p
JOIN gold.fct_payments f ON f.record_id = p.record_id
JOIN gold.dim_product  d ON d.product_type = p.product_type AND d.product_name = p.product_name;

-- payments with no product get one row, so totals still add up
INSERT INTO gold.bridge_payment_product (payment_key, product_slot, product_key, product_share)
SELECT f.payment_key, 0, -1, 1
FROM gold.fct_payments f
WHERE NOT EXISTS (SELECT 1 FROM gold.bridge_payment_product b WHERE b.payment_key = f.payment_key);

-- foreign keys and indexes (added after loading, which is much faster than checking them row by row)
ALTER TABLE gold.fct_payments
    ADD FOREIGN KEY (date_key)              REFERENCES gold.dim_date (date_key),
    ADD FOREIGN KEY (manufacturer_key)      REFERENCES gold.dim_manufacturer (manufacturer_key),
    ADD FOREIGN KEY (recipient_key)         REFERENCES gold.dim_recipient (recipient_key),
    ADD FOREIGN KEY (teaching_hospital_key) REFERENCES gold.dim_teaching_hospital (teaching_hospital_key),
    ADD FOREIGN KEY (recipient_type_key)    REFERENCES gold.lkp_recipient_type (recipient_type_key),
    ADD FOREIGN KEY (payment_nature_key)    REFERENCES gold.dim_payment_nature (payment_nature_key),
    ADD FOREIGN KEY (payment_form_key)      REFERENCES gold.dim_payment_form (payment_form_key),
    ADD FOREIGN KEY (travel_key)            REFERENCES gold.dim_travel (travel_key),
    ADD FOREIGN KEY (payment_flags_key)     REFERENCES gold.dim_payment_flags (payment_flags_key);

ALTER TABLE gold.bridge_payment_product
    ADD FOREIGN KEY (payment_key) REFERENCES gold.fct_payments (payment_key),
    ADD FOREIGN KEY (product_key) REFERENCES gold.dim_product (product_key);

CREATE INDEX ON gold.fct_payments (date_key);
CREATE INDEX ON gold.fct_payments (manufacturer_key);
CREATE INDEX ON gold.fct_payments (recipient_key);
CREATE INDEX ON gold.fct_payments (teaching_hospital_key);
CREATE INDEX ON gold.fct_payments (recipient_type_key);
CREATE INDEX ON gold.fct_payments (payment_nature_key);
CREATE INDEX ON gold.fct_payments (payment_form_key);
CREATE INDEX ON gold.fct_payments (travel_key);
CREATE INDEX ON gold.fct_payments (payment_flags_key);
CREATE INDEX ON gold.bridge_payment_product (product_key);
