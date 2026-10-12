-- Clean the raw table into two staging tables that the load step reads from.
-- The raw table is all text, so this step trims blanks, converts dates, numbers and ids, and unpivots the products.

SET work_mem = '1GB';

DROP TABLE IF EXISTS gold.stg_payments, gold.stg_payment_products;

-- One row per payment
CREATE TABLE gold.stg_payments AS
SELECT
    record_id::bigint                                                      AS record_id,
    TO_DATE(date_of_payment, 'MM/DD/YYYY')                                 AS payment_date,
    TO_DATE(payment_publication_date, 'MM/DD/YYYY')                        AS publication_date,
    total_amount_of_payment_usdollars::double precision                    AS total_payment_us_dollars,
    number_of_payments_included_in_total_amount::bigint                    AS number_of_payments,

    -- physician / practitioner
    NULLIF(TRIM(covered_recipient_profile_id), '')::bigint                 AS recipient_profile_id,
    NULLIF(TRIM(covered_recipient_npi), '')::bigint                        AS recipient_npi,
    NULLIF(CONCAT_WS(' ', INITCAP(NULLIF(TRIM(covered_recipient_first_name), '')),
                          INITCAP(NULLIF(TRIM(covered_recipient_middle_name), '')),
                          INITCAP(NULLIF(TRIM(covered_recipient_last_name), '')),
                          NULLIF(TRIM(covered_recipient_name_suffix), '')), '') AS full_name,
    COALESCE(NULLIF(TRIM(covered_recipient_type), ''), 'Unknown')          AS recipient_type,
    NULLIF(TRIM(covered_recipient_primary_type_1), '')                     AS primary_type,
    NULLIF(TRIM(covered_recipient_specialty_1), '')                        AS specialty,

    -- address (the physician's, or the hospital's on hospital payments)
    NULLIF(TRIM(recipient_primary_business_street_address_line1), '')      AS address_line1,
    INITCAP(NULLIF(TRIM(recipient_city), ''))                              AS city,
    UPPER(NULLIF(TRIM(recipient_state), ''))                               AS state_code,
    NULLIF(TRIM(recipient_zip_code), '')                                   AS zip_code,
    INITCAP(NULLIF(TRIM(recipient_country), ''))                           AS country,

    -- teaching hospital
    NULLIF(TRIM(teaching_hospital_id), '')::bigint                         AS teaching_hospital_id,
    NULLIF(TRIM(teaching_hospital_name), '')                               AS hospital_name,
    NULLIF(TRIM(teaching_hospital_ccn), '')                                AS hospital_ccn,

    -- manufacturer
    NULLIF(TRIM(applicable_manufacturer_or_applicable_gpo_making_payment_id), '')      AS manufacturer_id,
    NULLIF(TRIM(applicable_manufacturer_or_applicable_gpo_making_payment_name), '')    AS manufacturer_name,
    UPPER(NULLIF(TRIM(applicable_manufacturer_or_applicable_gpo_making_payment_state), '')) AS manufacturer_state,
    INITCAP(NULLIF(TRIM(applicable_manufacturer_or_applicable_gpo_making_payment_country), '')) AS manufacturer_country,

    -- payment nature and form
    COALESCE(NULLIF(TRIM(nature_of_payment_or_transfer_of_value), ''), 'Unknown') AS payment_nature,
    COALESCE(NULLIF(TRIM(form_of_payment_or_transfer_of_value), ''), 'Unknown')   AS payment_form,

    -- travel
    COALESCE(INITCAP(NULLIF(TRIM(city_of_travel), '')), 'N/A')             AS travel_city,
    COALESCE(UPPER(NULLIF(TRIM(state_of_travel), '')), 'N/A')              AS travel_state,
    COALESCE(INITCAP(NULLIF(TRIM(country_of_travel), '')), 'N/A')          AS travel_country,

    -- Yes/No indicators
    COALESCE(NULLIF(TRIM(change_type), ''), 'N/A')                         AS change_type,
    COALESCE(NULLIF(TRIM(physician_ownership_indicator), ''), 'N/A')       AS physician_ownership,
    COALESCE(NULLIF(TRIM(third_party_payment_recipient_indicator), ''), 'N/A') AS third_party_payment,
    COALESCE(NULLIF(TRIM(charity_indicator), ''), 'N/A')                   AS charity,
    COALESCE(NULLIF(TRIM(third_party_equals_covered_recipient_indicator), ''), 'N/A') AS third_party_is_recipient,
    COALESCE(NULLIF(TRIM(delay_in_publication_indicator), ''), 'N/A')      AS delay_in_publication,
    COALESCE(NULLIF(TRIM(dispute_status_for_publication), ''), 'N/A')      AS dispute_status,
    COALESCE(NULLIF(TRIM(related_product_indicator), ''), 'N/A')           AS related_product
FROM raw_layer.open_payments_general;

-- One row per payment and product (a payment lists up to 5 products)
CREATE TABLE gold.stg_payment_products AS
SELECT r.record_id::bigint AS record_id,
       p.slot,
       INITCAP(NULLIF(TRIM(p.product_name), ''))     AS product_name,
       COALESCE(NULLIF(TRIM(p.product_type), ''), 'N/A') AS product_type,
       NULLIF(TRIM(p.product_category), '')          AS product_category,
       NULLIF(TRIM(p.ndc), '')                       AS ndc,
       NULLIF(TRIM(p.pdi), '')                       AS pdi
FROM raw_layer.open_payments_general r
CROSS JOIN LATERAL (VALUES
    (1, r.name_of_drug_or_biological_or_device_or_medical_supply_1, r.indicate_drug_or_biological_or_device_or_medical_supply_1, r.product_category_or_therapeutic_area_1, r.associated_drug_or_biological_ndc_1, r.associated_device_or_medical_supply_pdi_1),
    (2, r.name_of_drug_or_biological_or_device_or_medical_supply_2, r.indicate_drug_or_biological_or_device_or_medical_supply_2, r.product_category_or_therapeutic_area_2, r.associated_drug_or_biological_ndc_2, r.associated_device_or_medical_supply_pdi_2),
    (3, r.name_of_drug_or_biological_or_device_or_medical_supply_3, r.indicate_drug_or_biological_or_device_or_medical_supply_3, r.product_category_or_therapeutic_area_3, r.associated_drug_or_biological_ndc_3, r.associated_device_or_medical_supply_pdi_3),
    (4, r.name_of_drug_or_biological_or_device_or_medical_supply_4, r.indicate_drug_or_biological_or_device_or_medical_supply_4, r.product_category_or_therapeutic_area_4, r.associated_drug_or_biological_ndc_4, r.associated_device_or_medical_supply_pdi_4),
    (5, r.name_of_drug_or_biological_or_device_or_medical_supply_5, r.indicate_drug_or_biological_or_device_or_medical_supply_5, r.product_category_or_therapeutic_area_5, r.associated_drug_or_biological_ndc_5, r.associated_device_or_medical_supply_pdi_5)
) AS p(slot, product_name, product_type, product_category, ndc, pdi)
WHERE NULLIF(TRIM(p.product_name), '') IS NOT NULL;

ANALYZE gold.stg_payments;
ANALYZE gold.stg_payment_products;
