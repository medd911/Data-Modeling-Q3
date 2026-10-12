-- Star schema diagram script (MySQL dialect), for drawing the gold model in drawSQL.
-- Paste into drawSQL -> Import -> MySQL. For the diagram only:
-- the deployable PostgreSQL DDL is sql/gold/01_create_gold_tables.sql and sql/gold/03_product_bridge.sql.

CREATE TABLE dim_date (
    date_key        INT PRIMARY KEY,
    full_date       DATE,
    day_of_month    SMALLINT,
    month_number    SMALLINT,
    month_name      VARCHAR(20),
    month_short     VARCHAR(3),
    quarter_number  SMALLINT,
    quarter_name    VARCHAR(10),
    year_number     SMALLINT,
    year_month      VARCHAR(10),
    year_quarter    VARCHAR(10),
    day_of_week     SMALLINT,
    day_name        VARCHAR(20),
    week_of_year    SMALLINT,
    is_weekend      BOOLEAN
);

CREATE TABLE dim_manufacturer (
    manufacturer_key              BIGINT PRIMARY KEY,
    manufacturer_id               VARCHAR(30) UNIQUE,
    manufacturer_name             VARCHAR(300),
    submitting_manufacturer_name  VARCHAR(300),
    manufacturer_state            VARCHAR(10),
    manufacturer_country          VARCHAR(100)
);

CREATE TABLE dim_recipient (
    recipient_key         BIGINT PRIMARY KEY,
    recipient_profile_id  BIGINT UNIQUE,
    recipient_npi         BIGINT,
    first_name            VARCHAR(100),
    middle_name           VARCHAR(100),
    last_name             VARCHAR(100),
    name_suffix           VARCHAR(20),
    full_name             VARCHAR(300),
    recipient_type        VARCHAR(60),
    primary_type          VARCHAR(200),
    specialty             VARCHAR(300),
    license_state         VARCHAR(10),
    address_line1         VARCHAR(200),
    address_line2         VARCHAR(200),
    city                  VARCHAR(100),
    state_code            VARCHAR(10),
    zip_code              VARCHAR(20),
    country               VARCHAR(100),
    province              VARCHAR(100),
    postal_code           VARCHAR(30)
);

CREATE TABLE dim_teaching_hospital (
    teaching_hospital_key  BIGINT PRIMARY KEY,
    teaching_hospital_id   BIGINT UNIQUE,
    hospital_name          VARCHAR(300),
    hospital_ccn           VARCHAR(20),
    address_line1          VARCHAR(200),
    city                   VARCHAR(100),
    state_code             VARCHAR(10),
    zip_code               VARCHAR(20)
);

CREATE TABLE dim_payment_nature (
    payment_nature_key  BIGINT PRIMARY KEY,
    payment_nature      VARCHAR(300) UNIQUE
);

CREATE TABLE dim_payment_form (
    payment_form_key  BIGINT PRIMARY KEY,
    payment_form      VARCHAR(100) UNIQUE
);

CREATE TABLE dim_travel (
    travel_key      BIGINT PRIMARY KEY,
    travel_city     VARCHAR(100),
    travel_state    VARCHAR(10),
    travel_country  VARCHAR(100)
);

CREATE TABLE dim_payment_flags (
    payment_flags_key         BIGINT PRIMARY KEY,
    change_type               VARCHAR(30),
    physician_ownership       VARCHAR(10),
    third_party_payment       VARCHAR(60),
    charity                   VARCHAR(10),
    third_party_is_recipient  VARCHAR(10),
    delay_in_publication      VARCHAR(10),
    dispute_status            VARCHAR(10),
    related_product           VARCHAR(10)
);

CREATE TABLE lkp_recipient_type (
    recipient_type_key  BIGINT PRIMARY KEY,
    recipient_type      VARCHAR(60) UNIQUE
);

CREATE TABLE dim_product (
    product_key       BIGINT PRIMARY KEY,
    product_bk        CHAR(32) UNIQUE,
    product_name      VARCHAR(300),
    product_type      VARCHAR(50),
    product_category  VARCHAR(300),
    ndc               VARCHAR(50),
    pdi               VARCHAR(50)
);

CREATE TABLE fct_payments (
    payment_key                                  BIGINT PRIMARY KEY,
    record_id                                    BIGINT UNIQUE,
    date_key                                     INT NOT NULL,
    manufacturer_key                             BIGINT NOT NULL,
    recipient_key                                BIGINT NOT NULL,
    teaching_hospital_key                        BIGINT NOT NULL,
    recipient_type_key                           BIGINT NOT NULL,
    payment_nature_key                           BIGINT NOT NULL,
    payment_form_key                             BIGINT NOT NULL,
    travel_key                                   BIGINT NOT NULL,
    payment_flags_key                            BIGINT NOT NULL,
    total_payment_us_dollars                     DOUBLE NOT NULL,
    number_of_payments_included_in_total_amount  BIGINT NOT NULL,
    FOREIGN KEY (date_key)              REFERENCES dim_date (date_key),
    FOREIGN KEY (manufacturer_key)      REFERENCES dim_manufacturer (manufacturer_key),
    FOREIGN KEY (recipient_key)         REFERENCES dim_recipient (recipient_key),
    FOREIGN KEY (teaching_hospital_key) REFERENCES dim_teaching_hospital (teaching_hospital_key),
    FOREIGN KEY (recipient_type_key)    REFERENCES lkp_recipient_type (recipient_type_key),
    FOREIGN KEY (payment_nature_key)    REFERENCES dim_payment_nature (payment_nature_key),
    FOREIGN KEY (payment_form_key)      REFERENCES dim_payment_form (payment_form_key),
    FOREIGN KEY (travel_key)            REFERENCES dim_travel (travel_key),
    FOREIGN KEY (payment_flags_key)     REFERENCES dim_payment_flags (payment_flags_key)
);

CREATE TABLE bridge_payment_product (
    payment_key    BIGINT NOT NULL,
    product_slot   SMALLINT NOT NULL,
    product_key    BIGINT NOT NULL,
    product_share  DECIMAL(9,8) NOT NULL,
    PRIMARY KEY (payment_key, product_slot),
    FOREIGN KEY (payment_key) REFERENCES fct_payments (payment_key),
    FOREIGN KEY (product_key) REFERENCES dim_product (product_key)
);
