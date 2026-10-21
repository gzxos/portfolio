-- =====================================================================
-- Meridian Material Handling (fictional company) - Sales & Marketing Analytics
-- Target: PostgreSQL 14+
-- Schema: mart  (conformed dimensions + 8 fact tables, all data synthetic)
--
-- Design rules
--   * One source of truth per concept (branch, product, sales rep, customer)
--   * Dates are real DATE columns, never month-name text
--   * Business parameters live in ref_parameter, not inside report formulas
--   * Derived values (aging, price gap, outstanding backlog) belong in views
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS mart;
SET search_path TO mart;

-- ---------------------------------------------------------------------
-- DIMENSIONS
-- ---------------------------------------------------------------------

CREATE TABLE dim_date (
    date_key     date        PRIMARY KEY,
    year         smallint    NOT NULL,
    quarter      smallint    NOT NULL CHECK (quarter BETWEEN 1 AND 4),
    month_num    smallint    NOT NULL CHECK (month_num BETWEEN 1 AND 12),
    month_name   char(3)     NOT NULL,
    year_month   char(7)     NOT NULL,          -- 'YYYY-MM'
    month_start  date        NOT NULL
);

INSERT INTO dim_date (date_key, year, quarter, month_num, month_name, year_month, month_start)
SELECT d::date,
       EXTRACT(YEAR    FROM d)::smallint,
       EXTRACT(QUARTER FROM d)::smallint,
       EXTRACT(MONTH   FROM d)::smallint,
       (ARRAY['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'])
           [EXTRACT(MONTH FROM d)::int],
       to_char(d, 'YYYY-MM'),
       date_trunc('month', d)::date
FROM generate_series('2021-01-01'::date, '2026-12-31'::date, interval '1 day') AS g(d);

CREATE TABLE dim_branch (
    branch_code  char(3)      PRIMARY KEY,
    branch_name  varchar(40)  NOT NULL,
    region       varchar(30)  NOT NULL,
    province     varchar(40)  NOT NULL
);

CREATE TABLE dim_product_line (
    product_line_code  char(3)      PRIMARY KEY,   -- e.g. ATL, NRV
    product_line_name  varchar(60)  NOT NULL
);

CREATE TABLE dim_sales_rep (
    sales_rep_id       serial       PRIMARY KEY,
    rep_name           varchar(80)  NOT NULL UNIQUE,   -- synthetic names only
    branch_code        char(3)      NOT NULL REFERENCES dim_branch (branch_code),
    product_line_code  char(3)      REFERENCES dim_product_line (product_line_code)
);

CREATE TABLE dim_customer (
    customer_id           serial        PRIMARY KEY,
    customer_name         varchar(120)  NOT NULL,
    customer_group        varchar(40)   NOT NULL,      -- 5 groups in the dummy data
    group_sort_order      smallint      NOT NULL,
    business_sector       varchar(60),
    industrial_area_type  varchar(25)
        CHECK (industrial_area_type IN ('Industrial Area', 'Non Industrial Area')),
    customer_base_flag    varchar(10)   NOT NULL DEFAULT 'UNDEFINED'
        CHECK (customer_base_flag IN ('CB', 'NCB', 'NEW', 'UNDEFINED')),
    origin_company        varchar(20)
        CHECK (origin_company IN ('Local', 'Japan', 'Korea', 'China', 'Europe', 'Other')),
    branch_code           char(3)       NOT NULL REFERENCES dim_branch (branch_code),
    sales_rep_id          integer       REFERENCES dim_sales_rep (sales_rep_id),
    site_province         varchar(40)   NOT NULL       -- where the units actually operate
);

CREATE TABLE dim_brand (
    brand_code  varchar(8)   PRIMARY KEY,
    brand_name  varchar(60)  NOT NULL,
    brand_type  varchar(12)  NOT NULL CHECK (brand_type IN ('Own Brand', 'Competitor'))
);

CREATE TABLE dim_product (
    product_id         serial       PRIMARY KEY,
    material_code      varchar(20)  NOT NULL UNIQUE,
    model              varchar(40)  NOT NULL,
    product_line_code  char(3)      NOT NULL REFERENCES dim_product_line (product_line_code),
    power_type         varchar(10)  NOT NULL CHECK (power_type IN ('Electric', 'Engine')),
    unit_class         varchar(10),
    battery_type       varchar(3)   CHECK (battery_type IN ('LAB', 'LIB')),   -- electric units only
    capacity_ton       numeric(4,1)
);

-- ---------------------------------------------------------------------
-- FACTS
-- ---------------------------------------------------------------------

-- Grain: one invoice line
CREATE TABLE fact_retail_sales (
    sales_line_id  bigserial      PRIMARY KEY,
    bill_doc       bigint         NOT NULL,
    sales_doc      bigint,
    billing_date   date           NOT NULL REFERENCES dim_date (date_key),
    customer_id    integer        NOT NULL REFERENCES dim_customer (customer_id),
    branch_code    char(3)        NOT NULL REFERENCES dim_branch (branch_code),
    sales_rep_id   integer        NOT NULL REFERENCES dim_sales_rep (sales_rep_id),
    product_id     integer        NOT NULL REFERENCES dim_product (product_id),
    invoiced_qty   integer        NOT NULL CHECK (invoiced_qty <> 0),   -- negative = credit note
    amount         numeric(16,2)  NOT NULL,
    segment_type   varchar(10)    CHECK (segment_type IN ('New', 'Existing'))
);

-- Grain: branch x product line x month x plan type
CREATE TABLE fact_sales_plan (
    plan_id            serial         PRIMARY KEY,
    month_start        date           NOT NULL REFERENCES dim_date (date_key)
        CHECK (EXTRACT(DAY FROM month_start) = 1),
    branch_code        char(3)        NOT NULL REFERENCES dim_branch (branch_code),
    product_line_code  char(3)        NOT NULL REFERENCES dim_product_line (product_line_code),
    plan_type          varchar(8)     NOT NULL CHECK (plan_type IN ('PLAN', 'OUTLOOK')),
    qty_projection     integer        NOT NULL CHECK (qty_projection >= 0),
    amount_projection  numeric(18,2)  NOT NULL,
    gross_projection   numeric(18,2),
    UNIQUE (month_start, branch_code, product_line_code, plan_type)
);

-- Grain: one customer purchase order line.
-- Outstanding backlog = delivered_date IS NULL (or > as-of date, see views).
CREATE TABLE fact_cpo_order (
    cpo_line_id         bigserial      PRIMARY KEY,
    cpo_no              bigint         NOT NULL,
    cpo_date            date           NOT NULL REFERENCES dim_date (date_key),
    customer_id         integer        NOT NULL REFERENCES dim_customer (customer_id),
    branch_code         char(3)        NOT NULL REFERENCES dim_branch (branch_code),
    sales_rep_id        integer        NOT NULL REFERENCES dim_sales_rep (sales_rep_id),
    product_id          integer        NOT NULL REFERENCES dim_product (product_id),
    order_qty           integer        NOT NULL CHECK (order_qty > 0),
    amount              numeric(16,2)  NOT NULL,
    serial_no           varchar(30),
    status_unit         varchar(10)    NOT NULL CHECK (status_unit IN ('SOH', 'On Vessel', 'SOO')),
    plan_delivery_date  date,
    eta_date            date,
    delivered_date      date           REFERENCES dim_date (date_key),
    CHECK (delivered_date IS NULL OR delivered_date >= cpo_date)
);

-- Grain: one unit in the supply pipeline. Aging is computed in a view.
CREATE TABLE fact_stock_pipeline (
    unit_id                  bigserial    PRIMARY KEY,
    serial_no                varchar(30)  UNIQUE,
    product_id               integer      NOT NULL REFERENCES dim_product (product_id),
    sales_rep_id             integer      REFERENCES dim_sales_rep (sales_rep_id),
    pipeline_status          varchar(10)  NOT NULL CHECK (pipeline_status IN ('SOO', 'SOH', 'On Vessel')),
    order_date               date         NOT NULL REFERENCES dim_date (date_key),
    received_date            date         REFERENCES dim_date (date_key),
    expected_lead_time_days  integer      CHECK (expected_lead_time_days >= 0),
    CHECK (received_date IS NULL OR received_date >= order_date)
);

-- Grain: one sales opportunity (new product business)
CREATE TABLE fact_opportunity (
    opportunity_id  serial         PRIMARY KEY,
    created_date    date           NOT NULL REFERENCES dim_date (date_key),
    branch_code     char(3)        NOT NULL REFERENCES dim_branch (branch_code),
    customer_id     integer        NOT NULL REFERENCES dim_customer (customer_id),
    sales_rep_id    integer        NOT NULL REFERENCES dim_sales_rep (sales_rep_id),
    product_id      integer        NOT NULL REFERENCES dim_product (product_id),
    qty             integer        NOT NULL CHECK (qty > 0),
    amount          numeric(16,2),
    status          varchar(10)    NOT NULL
        CHECK (status IN ('Won', 'Closed', 'Cold', 'Warm', 'Hot', 'Lost')),
    activity_stage  varchar(25)
        CHECK (activity_stage IN ('Planning a Promotion', 'Product Demo', 'Sent Quotation',
                                  'Under Customer Review', 'Hold', 'Won', 'Lost')),
    plan_po_month   date,
    last_update     date,
    next_action     varchar(200)
);

-- Grain: one lost deal. Price gap and totals are computed in a view.
CREATE TABLE fact_lost_deal (
    lost_deal_id           serial         PRIMARY KEY,
    lost_date              date           NOT NULL REFERENCES dim_date (date_key),
    sales_rep_id           integer        NOT NULL REFERENCES dim_sales_rep (sales_rep_id),
    customer_id            integer        NOT NULL REFERENCES dim_customer (customer_id),
    branch_code            char(3)        NOT NULL REFERENCES dim_branch (branch_code),
    product_id             integer        NOT NULL REFERENCES dim_product (product_id),
    qty                    integer        NOT NULL CHECK (qty > 0),
    our_unit_price         numeric(16,2)  NOT NULL,
    competitor_brand_code  varchar(8)     REFERENCES dim_brand (brand_code),
    competitor_unit_price  numeric(16,2),
    lost_reason            varchar(60)    NOT NULL,
    lost_description       varchar(300),
    prospect_date          date,
    quotation_date         date,
    CHECK (prospect_date IS NULL OR quotation_date IS NULL OR quotation_date >= prospect_date)
);

-- Grain: customer x brand x year (units in operation at customer sites)
CREATE TABLE fact_uio (
    customer_id  integer     NOT NULL REFERENCES dim_customer (customer_id),
    brand_code   varchar(8)  NOT NULL REFERENCES dim_brand (brand_code),
    year         smallint    NOT NULL CHECK (year BETWEEN 2015 AND 2100),
    uio_count    integer     NOT NULL CHECK (uio_count >= 0),
    PRIMARY KEY (customer_id, brand_code, year)
);

-- Grain: one import declaration line
CREATE TABLE fact_import (
    import_id          bigserial      PRIMARY KEY,
    declaration_no     varchar(20)    NOT NULL,
    declaration_date   date           NOT NULL REFERENCES dim_date (date_key),
    brand_code         varchar(8)     NOT NULL REFERENCES dim_brand (brand_code),
    origin_country     varchar(40)    NOT NULL,
    supplier_name      varchar(120),
    supplier_port      varchar(60),
    arrival_port       varchar(60),
    importer_name      varchar(120)   NOT NULL,
    hs_code            varchar(12),
    goods_description  varchar(200),
    goods_type         varchar(40),
    unit_class         varchar(10),
    classification     varchar(30),
    capacity_ton       numeric(4,1),
    qty                integer        NOT NULL CHECK (qty > 0),
    net_weight_kg      numeric(12,2),
    value_idr          numeric(18,2)  NOT NULL,
    value_usd          numeric(14,2),
    unit_price_idr     numeric(16,2)  GENERATED ALWAYS AS (value_idr / qty) STORED
);

-- ---------------------------------------------------------------------
-- PARAMETERS (replaces numbers hard-coded in report formulas)
-- Examples: gross_margin_pct (scope = product line), cpo_target_multiplier,
--           visit_target_per_month, new_product_target_amount
-- ---------------------------------------------------------------------

CREATE TABLE ref_parameter (
    param_name   varchar(60)    NOT NULL,
    scope        varchar(10)    NOT NULL DEFAULT 'ALL',   -- product line code or ALL
    valid_from   date           NOT NULL,
    valid_to     date,
    param_value  numeric(18,4)  NOT NULL,
    description  varchar(200),
    PRIMARY KEY (param_name, scope, valid_from),
    CHECK (valid_to IS NULL OR valid_to >= valid_from)
);

-- ---------------------------------------------------------------------
-- INDEXES (foreign keys on the larger fact tables)
-- ---------------------------------------------------------------------

CREATE INDEX ix_sales_date      ON fact_retail_sales (billing_date);
CREATE INDEX ix_sales_customer  ON fact_retail_sales (customer_id);
CREATE INDEX ix_sales_branch    ON fact_retail_sales (branch_code);
CREATE INDEX ix_sales_product   ON fact_retail_sales (product_id);
CREATE INDEX ix_cpo_date        ON fact_cpo_order (cpo_date);
CREATE INDEX ix_cpo_customer    ON fact_cpo_order (customer_id);
CREATE INDEX ix_cpo_open        ON fact_cpo_order (cpo_date) WHERE delivered_date IS NULL;
CREATE INDEX ix_opp_status      ON fact_opportunity (status);
CREATE INDEX ix_lost_date       ON fact_lost_deal (lost_date);
CREATE INDEX ix_import_date     ON fact_import (declaration_date);
CREATE INDEX ix_uio_brand       ON fact_uio (brand_code);
