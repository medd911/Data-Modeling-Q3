-- Load the gold star schema from raw_layer.open_payments_general.
-- Run after 01_create_gold_tables.sql. Safe to re-run: it rebuilds gold from the raw table.
--
--   Step 1  helper functions   (cleaning rules)
--   Step 2  gold.stg_general   (clean, type-cast, deduplicate to one row per Record_ID)
--   Step 3  dimensions and the recipient-type lookup
--   Step 4  fact
--   Step 5  foreign keys and indexes on the fact

-- Large sorts spill to disk with the default work_mem; raise it for this session only.
SET work_mem = '1GB';

DROP MATERIALIZED VIEW IF EXISTS gold.stg_general CASCADE;

-- Step 1: helper functions
CREATE OR REPLACE FUNCTION gold.clean_text(p_value text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT nullif(btrim(regexp_replace(coalesce(p_value,''), '\s+', ' ', 'g')), '');
$$;

CREATE OR REPLACE FUNCTION gold.clean_name(p_value text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT initcap(lower(gold.clean_text(p_value)));
$$;

CREATE OR REPLACE FUNCTION gold.norm_state(p_value text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN upper(btrim(coalesce(p_value,''))) ~ '^[A-Z]{2}$'
        THEN upper(btrim(p_value))
        ELSE nullif(btrim(p_value), '')
    END;
$$;

CREATE OR REPLACE FUNCTION gold.norm_yn(p_value text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN p_value IS NULL OR btrim(p_value) = ''            THEN 'N/A'
        WHEN lower(btrim(p_value)) IN ('yes','y','true','1')   THEN 'Yes'
        WHEN lower(btrim(p_value)) IN ('no','n','false','0')   THEN 'No'
        ELSE initcap(btrim(p_value))
    END;
$$;

CREATE OR REPLACE FUNCTION gold.parse_date(p_value text)
RETURNS date LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    RETURN to_date(nullif(btrim(p_value), ''), 'MM/DD/YYYY');
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION gold.safe_bigint(p_value text)
RETURNS bigint LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_value IS NULL OR btrim(p_value) !~ '^[0-9]+$' THEN
        RETURN NULL;
    END IF;
    RETURN btrim(p_value)::bigint;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$;


-- Step 2: staging (one cleaned row per Record_ID, latest published version wins)
CREATE MATERIALIZED VIEW gold.stg_general AS
SELECT DISTINCT ON (record_id) *
FROM (
    SELECT
        gold.safe_bigint(record_id)                                    AS record_id,
        gold.parse_date(date_of_payment)                               AS payment_date,
        gold.parse_date(payment_publication_date)                      AS payment_publication_date,

        CASE WHEN regexp_replace(coalesce(total_amount_of_payment_usdollars,''), '[^0-9.\-]','','g') ~ '^-?[0-9]+(\.[0-9]+)?$'
             THEN regexp_replace(total_amount_of_payment_usdollars, '[^0-9.\-]','','g')::double precision END AS total_payment_us_dollars,
        CASE WHEN regexp_replace(coalesce(number_of_payments_included_in_total_amount,''), '[^0-9]','','g') ~ '^[0-9]{1,9}$'
             THEN regexp_replace(number_of_payments_included_in_total_amount, '[^0-9]','','g')::bigint END     AS number_of_payments,

        -- recipient (physician / practitioner)
        gold.safe_bigint(covered_recipient_profile_id)                 AS recipient_profile_id,
        gold.safe_bigint(covered_recipient_npi)                        AS recipient_npi,
        gold.clean_name(covered_recipient_first_name)                  AS first_name,
        gold.clean_name(covered_recipient_middle_name)                 AS middle_name,
        gold.clean_name(covered_recipient_last_name)                   AS last_name,
        gold.clean_text(covered_recipient_name_suffix)                 AS name_suffix,
        coalesce(gold.clean_text(covered_recipient_type), 'Unknown')   AS recipient_type,
        gold.clean_text(covered_recipient_primary_type_1)              AS primary_type,
        gold.clean_text(covered_recipient_specialty_1)                 AS specialty,
        gold.norm_state(covered_recipient_license_state_code1)         AS license_state,

        -- address (the recipient's, or the hospital's on hospital payments)
        gold.clean_text(recipient_primary_business_street_address_line1) AS address_line1,
        gold.clean_text(recipient_primary_business_street_address_line2) AS address_line2,
        gold.clean_name(recipient_city)                                AS city,
        gold.norm_state(recipient_state)                               AS state_code,
        nullif(regexp_replace(coalesce(recipient_zip_code,''),'[^0-9]','','g'),'') AS zip_code,
        gold.clean_name(recipient_country)                             AS country,
        gold.clean_text(recipient_province)                            AS province,
        gold.clean_text(recipient_postal_code)                         AS postal_code,

        -- teaching hospital
        gold.safe_bigint(teaching_hospital_id)                         AS teaching_hospital_id,
        gold.clean_text(teaching_hospital_name)                        AS teaching_hospital_name,
        gold.clean_text(teaching_hospital_ccn)                         AS teaching_hospital_ccn,

        -- manufacturer
        gold.clean_text(applicable_manufacturer_or_applicable_gpo_making_payment_id)    AS manufacturer_id,
        gold.clean_text(applicable_manufacturer_or_applicable_gpo_making_payment_name)  AS manufacturer_name,
        gold.clean_text(submitting_applicable_manufacturer_or_applicable_gpo_name)      AS submitting_manufacturer_name,
        gold.norm_state(applicable_manufacturer_or_applicable_gpo_making_payment_state) AS manufacturer_state,
        gold.clean_name(applicable_manufacturer_or_applicable_gpo_making_payment_country) AS manufacturer_country,

        -- products (up to 5 per payment; unpivoted in 03_product_bridge.sql)
        gold.clean_text(name_of_drug_or_biological_or_device_or_medical_supply_1) AS marketed_name_of_product_1,
        gold.clean_text(name_of_drug_or_biological_or_device_or_medical_supply_2) AS marketed_name_of_product_2,
        gold.clean_text(name_of_drug_or_biological_or_device_or_medical_supply_3) AS marketed_name_of_product_3,
        gold.clean_text(name_of_drug_or_biological_or_device_or_medical_supply_4) AS marketed_name_of_product_4,
        gold.clean_text(name_of_drug_or_biological_or_device_or_medical_supply_5) AS marketed_name_of_product_5,
        gold.clean_text(indicate_drug_or_biological_or_device_or_medical_supply_1) AS type_of_product_1,
        gold.clean_text(indicate_drug_or_biological_or_device_or_medical_supply_2) AS type_of_product_2,
        gold.clean_text(indicate_drug_or_biological_or_device_or_medical_supply_3) AS type_of_product_3,
        gold.clean_text(indicate_drug_or_biological_or_device_or_medical_supply_4) AS type_of_product_4,
        gold.clean_text(indicate_drug_or_biological_or_device_or_medical_supply_5) AS type_of_product_5,
        gold.clean_text(product_category_or_therapeutic_area_1) AS product_category_1,
        gold.clean_text(product_category_or_therapeutic_area_2) AS product_category_2,
        gold.clean_text(product_category_or_therapeutic_area_3) AS product_category_3,
        gold.clean_text(product_category_or_therapeutic_area_4) AS product_category_4,
        gold.clean_text(product_category_or_therapeutic_area_5) AS product_category_5,
        gold.clean_text(associated_drug_or_biological_ndc_1) AS ndc_of_product_1,
        gold.clean_text(associated_drug_or_biological_ndc_2) AS ndc_of_product_2,
        gold.clean_text(associated_drug_or_biological_ndc_3) AS ndc_of_product_3,
        gold.clean_text(associated_drug_or_biological_ndc_4) AS ndc_of_product_4,
        gold.clean_text(associated_drug_or_biological_ndc_5) AS ndc_of_product_5,
        gold.clean_text(associated_device_or_medical_supply_pdi_1) AS pdi_of_product_1,
        gold.clean_text(associated_device_or_medical_supply_pdi_2) AS pdi_of_product_2,
        gold.clean_text(associated_device_or_medical_supply_pdi_3) AS pdi_of_product_3,
        gold.clean_text(associated_device_or_medical_supply_pdi_4) AS pdi_of_product_4,
        gold.clean_text(associated_device_or_medical_supply_pdi_5) AS pdi_of_product_5,

        -- payment nature and form
        coalesce(gold.clean_text(nature_of_payment_or_transfer_of_value), 'Unknown') AS payment_nature,
        coalesce(gold.clean_text(form_of_payment_or_transfer_of_value),   'Unknown') AS payment_form,

        -- travel
        coalesce(gold.clean_name(city_of_travel),    'N/A')            AS travel_city,
        coalesce(gold.norm_state(state_of_travel),   'N/A')            AS travel_state,
        coalesce(gold.clean_name(country_of_travel), 'N/A')            AS travel_country,

        -- indicator flags
        coalesce(gold.clean_text(change_type), 'N/A')                  AS change_type,
        gold.norm_yn(physician_ownership_indicator)                    AS physician_ownership,
        coalesce(gold.clean_text(third_party_payment_recipient_indicator), 'N/A') AS third_party_payment,
        gold.norm_yn(charity_indicator)                                AS charity,
        gold.norm_yn(third_party_equals_covered_recipient_indicator)   AS third_party_is_recipient,
        gold.norm_yn(delay_in_publication_indicator)                   AS delay_in_publication,
        gold.norm_yn(dispute_status_for_publication)                   AS dispute_status,
        gold.norm_yn(related_product_indicator)                        AS related_product
    FROM raw_layer.open_payments_general
) cleaned
WHERE record_id IS NOT NULL
ORDER BY record_id, payment_publication_date DESC NULLS LAST, payment_date DESC NULLS LAST;

CREATE UNIQUE INDEX ux_stg_general_record_id ON gold.stg_general (record_id);
ANALYZE gold.stg_general;


-- Step 3: dimensions
-- Remove the fact's foreign keys and indexes first, so a re-run loads without them (Step 5 adds them back).
ALTER TABLE gold.fct_payments
    DROP CONSTRAINT IF EXISTS fk_fct_date,
    DROP CONSTRAINT IF EXISTS fk_fct_manufacturer,
    DROP CONSTRAINT IF EXISTS fk_fct_recipient,
    DROP CONSTRAINT IF EXISTS fk_fct_teaching_hospital,
    DROP CONSTRAINT IF EXISTS fk_fct_recipient_type,
    DROP CONSTRAINT IF EXISTS fk_fct_nature,
    DROP CONSTRAINT IF EXISTS fk_fct_form,
    DROP CONSTRAINT IF EXISTS fk_fct_travel,
    DROP CONSTRAINT IF EXISTS fk_fct_flags;
DROP INDEX IF EXISTS gold.ix_fct_date, gold.ix_fct_manufacturer, gold.ix_fct_recipient, gold.ix_fct_teaching_hospital,
                     gold.ix_fct_recipient_type, gold.ix_fct_nature, gold.ix_fct_form, gold.ix_fct_travel, gold.ix_fct_flags;

BEGIN;

TRUNCATE TABLE gold.fct_payments, gold.dim_recipient, gold.dim_teaching_hospital, gold.dim_manufacturer,
               gold.dim_travel, gold.dim_payment_form, gold.dim_payment_nature, gold.dim_payment_flags,
               gold.lkp_recipient_type, gold.dim_date
    RESTART IDENTITY CASCADE;

-- dim_date
INSERT INTO gold.dim_date (
    date_key, full_date, day_of_month, month_number, month_name, month_short,
    quarter_number, quarter_name, year_number, year_month, year_quarter,
    day_of_week, day_name, week_of_year, is_weekend)
SELECT
    to_char(d, 'YYYYMMDD')::integer, d::date,
    extract(day FROM d)::smallint, extract(month FROM d)::smallint,
    trim(to_char(d, 'Month')), to_char(d, 'Mon'),
    extract(quarter FROM d)::smallint, 'Q' || extract(quarter FROM d)::text,
    extract(year FROM d)::smallint, to_char(d, 'YYYY-MM'),
    to_char(d, 'YYYY') || '-Q' || extract(quarter FROM d)::text,
    extract(isodow FROM d)::smallint, trim(to_char(d, 'Day')),
    extract(week FROM d)::smallint, extract(isodow FROM d) IN (6, 7)
FROM generate_series(date '2013-01-01', date '2030-12-31', interval '1 day') AS g(d);

INSERT INTO gold.dim_date (date_key, month_name, quarter_name, year_month, year_quarter, day_name)
VALUES (-1, 'Unknown', 'Unknown', 'Unknown', 'Unknown', 'Unknown');

-- dim_recipient
INSERT INTO gold.dim_recipient (recipient_key, full_name, recipient_type) VALUES
    (-1, 'Unknown', 'Unknown'),
    (-2, 'Not Applicable (teaching hospital payment)', 'Not Applicable');

INSERT INTO gold.dim_recipient (
    recipient_profile_id, recipient_npi, first_name, middle_name, last_name, name_suffix, full_name,
    recipient_type, primary_type, specialty, license_state,
    address_line1, address_line2, city, state_code, zip_code, country, province, postal_code)
SELECT DISTINCT ON (recipient_profile_id)
    recipient_profile_id, recipient_npi, first_name, middle_name, last_name, name_suffix,
    nullif(btrim(concat_ws(' ', first_name, middle_name, last_name, name_suffix)), ''),
    recipient_type, primary_type, specialty, license_state,
    address_line1, address_line2, city, state_code, zip_code, country, province, postal_code
FROM gold.stg_general
WHERE recipient_profile_id IS NOT NULL
ORDER BY recipient_profile_id, payment_publication_date DESC NULLS LAST;

-- dim_teaching_hospital
INSERT INTO gold.dim_teaching_hospital (teaching_hospital_key, hospital_name) VALUES
    (-1, 'Unknown'),
    (-2, 'Not Applicable (physician payment)');

INSERT INTO gold.dim_teaching_hospital (
    teaching_hospital_id, hospital_name, hospital_ccn, address_line1, city, state_code, zip_code)
SELECT DISTINCT ON (teaching_hospital_id)
    teaching_hospital_id, teaching_hospital_name, teaching_hospital_ccn, address_line1, city, state_code, zip_code
FROM gold.stg_general
WHERE teaching_hospital_id IS NOT NULL
ORDER BY teaching_hospital_id, payment_publication_date DESC NULLS LAST;

-- dim_manufacturer
INSERT INTO gold.dim_manufacturer (manufacturer_key, manufacturer_name) VALUES (-1, 'Unknown');

INSERT INTO gold.dim_manufacturer (
    manufacturer_id, manufacturer_name, submitting_manufacturer_name, manufacturer_state, manufacturer_country)
SELECT DISTINCT ON (manufacturer_id)
    manufacturer_id, manufacturer_name, submitting_manufacturer_name, manufacturer_state, manufacturer_country
FROM gold.stg_general
WHERE manufacturer_id IS NOT NULL
ORDER BY manufacturer_id, payment_publication_date DESC NULLS LAST;

-- dim_travel (the 'N/A' row holds payments with no travel)
INSERT INTO gold.dim_travel (travel_city, travel_state, travel_country)
SELECT DISTINCT travel_city, travel_state, travel_country FROM gold.stg_general;

-- dim_payment_form, dim_payment_nature
INSERT INTO gold.dim_payment_form (payment_form)     SELECT DISTINCT payment_form   FROM gold.stg_general;
INSERT INTO gold.dim_payment_nature (payment_nature) SELECT DISTINCT payment_nature FROM gold.stg_general;

-- dim_payment_flags (junk dimension)
INSERT INTO gold.dim_payment_flags (
    change_type, physician_ownership, third_party_payment, charity,
    third_party_is_recipient, delay_in_publication, dispute_status, related_product)
SELECT DISTINCT change_type, physician_ownership, third_party_payment, charity,
                third_party_is_recipient, delay_in_publication, dispute_status, related_product
FROM gold.stg_general;

-- lkp_recipient_type
INSERT INTO gold.lkp_recipient_type (recipient_type) SELECT DISTINCT recipient_type FROM gold.stg_general;

-- Refresh statistics so the fact join is planned with real row counts.
ANALYZE gold.dim_recipient;
ANALYZE gold.dim_teaching_hospital;
ANALYZE gold.dim_manufacturer;
ANALYZE gold.dim_travel;
ANALYZE gold.dim_payment_form;
ANALYZE gold.dim_payment_nature;
ANALYZE gold.dim_payment_flags;
ANALYZE gold.lkp_recipient_type;
ANALYZE gold.dim_date;

COMMIT;


-- Step 4: fact
INSERT INTO gold.fct_payments (
    record_id, date_key, manufacturer_key, recipient_key, teaching_hospital_key, recipient_type_key,
    payment_nature_key, payment_form_key, travel_key, payment_flags_key,
    total_payment_us_dollars, number_of_payments_included_in_total_amount)
SELECT
    s.record_id,
    coalesce(d.date_key, -1),
    coalesce(m.manufacturer_key, -1),
    coalesce(r.recipient_key,         CASE WHEN s.teaching_hospital_id IS NOT NULL THEN -2 ELSE -1 END),
    coalesce(h.teaching_hospital_key, CASE WHEN s.recipient_profile_id IS NOT NULL THEN -2 ELSE -1 END),
    rt.recipient_type_key,
    n.payment_nature_key,
    f.payment_form_key,
    t.travel_key,
    fl.payment_flags_key,
    coalesce(s.total_payment_us_dollars, 0),
    coalesce(s.number_of_payments, 1)
FROM gold.stg_general s
LEFT JOIN gold.dim_date              d ON d.date_key = to_char(s.payment_date, 'YYYYMMDD')::integer
LEFT JOIN gold.dim_manufacturer      m ON m.manufacturer_id = s.manufacturer_id
LEFT JOIN gold.dim_recipient         r ON r.recipient_profile_id = s.recipient_profile_id
LEFT JOIN gold.dim_teaching_hospital h ON h.teaching_hospital_id = s.teaching_hospital_id
JOIN gold.lkp_recipient_type rt ON rt.recipient_type = s.recipient_type
JOIN gold.dim_payment_nature n  ON n.payment_nature  = s.payment_nature
JOIN gold.dim_payment_form   f  ON f.payment_form    = s.payment_form
JOIN gold.dim_travel         t  ON t.travel_city = s.travel_city
                               AND t.travel_state = s.travel_state
                               AND t.travel_country = s.travel_country
JOIN gold.dim_payment_flags  fl ON fl.change_type = s.change_type
                               AND fl.physician_ownership = s.physician_ownership
                               AND fl.third_party_payment = s.third_party_payment
                               AND fl.charity = s.charity
                               AND fl.third_party_is_recipient = s.third_party_is_recipient
                               AND fl.delay_in_publication = s.delay_in_publication
                               AND fl.dispute_status = s.dispute_status
                               AND fl.related_product = s.related_product;

ANALYZE gold.fct_payments;


-- Step 5: foreign keys and indexes on the fact
ALTER TABLE gold.fct_payments
    ADD CONSTRAINT fk_fct_date             FOREIGN KEY (date_key)              REFERENCES gold.dim_date (date_key),
    ADD CONSTRAINT fk_fct_manufacturer     FOREIGN KEY (manufacturer_key)      REFERENCES gold.dim_manufacturer (manufacturer_key),
    ADD CONSTRAINT fk_fct_recipient        FOREIGN KEY (recipient_key)         REFERENCES gold.dim_recipient (recipient_key),
    ADD CONSTRAINT fk_fct_teaching_hospital FOREIGN KEY (teaching_hospital_key) REFERENCES gold.dim_teaching_hospital (teaching_hospital_key),
    ADD CONSTRAINT fk_fct_recipient_type   FOREIGN KEY (recipient_type_key)    REFERENCES gold.lkp_recipient_type (recipient_type_key),
    ADD CONSTRAINT fk_fct_nature           FOREIGN KEY (payment_nature_key)    REFERENCES gold.dim_payment_nature (payment_nature_key),
    ADD CONSTRAINT fk_fct_form             FOREIGN KEY (payment_form_key)      REFERENCES gold.dim_payment_form (payment_form_key),
    ADD CONSTRAINT fk_fct_travel           FOREIGN KEY (travel_key)            REFERENCES gold.dim_travel (travel_key),
    ADD CONSTRAINT fk_fct_flags            FOREIGN KEY (payment_flags_key)     REFERENCES gold.dim_payment_flags (payment_flags_key);

CREATE INDEX ix_fct_date              ON gold.fct_payments (date_key);
CREATE INDEX ix_fct_manufacturer      ON gold.fct_payments (manufacturer_key);
CREATE INDEX ix_fct_recipient         ON gold.fct_payments (recipient_key);
CREATE INDEX ix_fct_teaching_hospital ON gold.fct_payments (teaching_hospital_key);
CREATE INDEX ix_fct_recipient_type    ON gold.fct_payments (recipient_type_key);
CREATE INDEX ix_fct_nature            ON gold.fct_payments (payment_nature_key);
CREATE INDEX ix_fct_form              ON gold.fct_payments (payment_form_key);
CREATE INDEX ix_fct_travel            ON gold.fct_payments (travel_key);
CREATE INDEX ix_fct_flags             ON gold.fct_payments (payment_flags_key);
