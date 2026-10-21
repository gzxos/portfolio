-- =====================================================================
-- Meridian Material Handling (fictional) - SYNTHETIC DATA SEED
-- Target  : PostgreSQL 14+, schema "mart" (jalankan SETELAH DDL + dim_date)
-- Periode : 2023-01-01 s/d 2026-10-19 (as-of date), plan sampai 2026-12
-- Sifat   : pure SQL, deterministik (setseed), aman di-run ulang
--           (TRUNCATE dulu semua tabel kecuali dim_date)
-- Catatan : jalankan dalam SATU session/script (pakai temp table + setseed)
-- =====================================================================

BEGIN;
SET search_path TO mart;

TRUNCATE fact_import, fact_uio, fact_lost_deal, fact_opportunity, fact_stock_pipeline,
         fact_cpo_order, fact_sales_plan, fact_retail_sales, ref_parameter,
         dim_product, dim_customer, dim_sales_rep, dim_brand, dim_product_line, dim_branch
RESTART IDENTITY CASCADE;

SELECT setseed(0.42);

-- ---------------------------------------------------------------------
-- HELPER (temp, hilang otomatis setelah selesai)
-- ---------------------------------------------------------------------

-- Bobot bulanan: tren naik + seasonality (dip Jan-Apr, puncak Nov-Des)
CREATE TEMP TABLE tmp_month ON COMMIT DROP AS
WITH m AS (
    SELECT d::date AS ms, row_number() OVER (ORDER BY d) AS idx
    FROM generate_series('2023-01-01'::date, '2026-10-01'::date, interval '1 month') AS g(d)
), w AS (
    SELECT ms,
           CASE WHEN ms = DATE '2026-10-01' THEN 19 ELSE ((ms + interval '1 month')::date - ms) END AS ndays,
           (1 + 0.015 * idx)
             * (ARRAY[0.85,0.90,0.95,0.85,1.00,1.00,1.05,1.00,1.10,1.15,1.20,1.30])[EXTRACT(MONTH FROM ms)::int]
             * (CASE WHEN ms = DATE '2026-10-01' THEN 19.0 / 31 ELSE 1 END) AS wt
    FROM m
), c AS (
    SELECT ms, ndays,
           CASE WHEN ms = max(ms) OVER () THEN 2.0
                ELSE sum(wt) OVER (ORDER BY ms) / sum(wt) OVER () END AS hi
    FROM w
)
SELECT ms, ndays, coalesce(lag(hi) OVER (ORDER BY ms), 0) AS lo, hi FROM c;

-- u,v = angka random 0..1 -> tanggal (terdistribusi mengikuti bobot bulanan)
CREATE FUNCTION pg_temp.rdate(u float8, v float8) RETURNS date
LANGUAGE sql STABLE AS $$
    SELECT (ms + floor(v * ndays)::int) FROM tmp_month WHERE u >= lo AND u < hi
$$;

-- kapasitas (ton) per product line dari angka random
CREATE FUNCTION pg_temp.cap_for(p_line text, r float8) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
    SELECT round((CASE p_line
        WHEN 'FLE' THEN 1.5 + 0.5 * floor(r * 10)
        WHEN 'RCH' THEN 1.4 + 0.2 * floor(r * 6)
        WHEN 'PLT' THEN 1.5 + 0.5 * floor(r * 4)
        WHEN 'STK' THEN 1.0 + 0.2 * floor(r * 6)
        WHEN 'ATL' THEN 1.0 + 0.5 * floor(r * 5)
        ELSE            1.0 + 0.2 * floor(r * 4) END)::numeric, 1)
$$;

-- harga jual dasar (IDR) per unit
CREATE FUNCTION pg_temp.base_price(p_line text, p_cap numeric, p_pwr text, p_bat text) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
    SELECT round((CASE p_line
            WHEN 'FLE' THEN 150e6 + 95e6  * p_cap
            WHEN 'RCH' THEN 450e6 + 150e6 * p_cap
            WHEN 'PLT' THEN  40e6 + 25e6  * p_cap
            WHEN 'STK' THEN  90e6 + 60e6  * p_cap
            WHEN 'ATL' THEN 300e6 + 120e6 * p_cap
            ELSE            900e6 + 400e6 * p_cap END)
        * (CASE WHEN p_pwr = 'Electric' AND p_line = 'FLE' THEN 1.35 ELSE 1 END)
        * (CASE WHEN p_bat = 'LIB' THEN 1.25 ELSE 1 END) / 1e6) * 1e6
$$;

-- ---------------------------------------------------------------------
-- DIMENSIONS
-- ---------------------------------------------------------------------

INSERT INTO dim_branch VALUES
    ('JKT', 'Jakarta',     'Jabodetabek', 'DKI Jakarta'),
    ('BKS', 'Bekasi',      'Jabodetabek', 'Jawa Barat'),
    ('KRW', 'Karawang',    'Jawa Barat',  'Jawa Barat'),
    ('SBY', 'Surabaya',    'Jawa Timur',  'Jawa Timur'),
    ('SMG', 'Semarang',    'Jawa Tengah', 'Jawa Tengah'),
    ('MDN', 'Medan',       'Sumatera',    'Sumatera Utara'),
    ('BPN', 'Balikpapan',  'Kalimantan',  'Kalimantan Timur'),
    ('MKS', 'Makassar',    'Sulawesi',    'Sulawesi Selatan');

INSERT INTO dim_product_line VALUES
    ('FLE', 'Forklift'),
    ('RCH', 'Reach Truck'),
    ('PLT', 'Pallet Truck'),
    ('STK', 'Stacker'),
    ('ATL', 'Autonomous Tow & Lifting'),
    ('NRV', 'Narrow Aisle Vehicle');

INSERT INTO dim_brand VALUES
    ('MRD', 'Meridian',       'Own Brand'),
    ('MRL', 'Meridian Lite',  'Own Brand'),
    ('MRX', 'Meridian Xtra',  'Own Brand'),
    ('MRE', 'Meridian Eco',   'Own Brand'),
    ('HKT', 'Hakuto',         'Competitor'),
    ('KNZ', 'Kanzen',         'Competitor'),
    ('SRL', 'Sunrise Lift',   'Competitor'),
    ('DRG', 'Dragon Haul',    'Competitor'),
    ('HNB', 'Hanbit Lift',    'Competitor'),
    ('EUL', 'Eurolift',       'Competitor'),
    ('NRD', 'Nordmann',       'Competitor'),
    ('BLR', 'Bluridge',       'Competitor');

-- 30 sales rep (nama sintetis, unik)
INSERT INTO dim_sales_rep (rep_name, branch_code, product_line_code)
SELECT (ARRAY['Andi','Budi','Citra','Dewi','Eko','Fajar','Gita','Hadi','Indra','Joko'])[(i - 1) % 10 + 1]
       || ' ' ||
       (ARRAY['Santoso','Wijaya','Pratama','Lestari','Hidayat','Kusuma','Nugroho','Saputra','Rahayu','Firmansyah'])
           [((i - 1) / 10 * 3 + (i - 1) % 10) % 10 + 1],
       (ARRAY['JKT','BKS','KRW','SBY','SMG','MDN','BPN','MKS',
              'JKT','BKS','KRW','SBY','SMG','MDN','BPN','MKS',
              'JKT','BKS','KRW','SBY','SMG','JKT','BKS','KRW','SBY','MDN','BPN','MKS','SBY','SMG'])[i],
       (ARRAY['FLE','RCH','PLT','STK','ATL','NRV'])[(i - 1) % 6 + 1]
FROM generate_series(1, 30) AS i;

-- 400 customer
INSERT INTO dim_customer (customer_name, customer_group, group_sort_order, business_sector,
                          industrial_area_type, customer_base_flag, origin_company,
                          branch_code, sales_rep_id, site_province)
WITH s AS (
    SELECT i, random() r_n1, random() r_n2, random() r_n3, random() r_grp, random() r_sec,
           random() r_flag, random() r_ind, random() r_org, random() r_br, random() r_rep,
           random() r_site, random() r_site2
    FROM generate_series(1, 400) AS i
), t AS (
    SELECT s.*,
        CASE WHEN r_grp < 0.30 THEN 1 WHEN r_grp < 0.50 THEN 2 WHEN r_grp < 0.70 THEN 3
             WHEN r_grp < 0.85 THEN 4 ELSE 5 END AS g,
        CASE WHEN r_flag < 0.40 THEN 'CB' WHEN r_flag < 0.65 THEN 'NCB'
             WHEN r_flag < 0.90 THEN 'NEW' ELSE 'UNDEFINED' END AS flag,
        CASE WHEN r_br < 0.20 THEN 'JKT' WHEN r_br < 0.38 THEN 'BKS' WHEN r_br < 0.55 THEN 'KRW'
             WHEN r_br < 0.72 THEN 'SBY' WHEN r_br < 0.82 THEN 'SMG' WHEN r_br < 0.90 THEN 'MDN'
             WHEN r_br < 0.96 THEN 'BPN' ELSE 'MKS' END AS br
    FROM s
)
SELECT 'PT ' || (ARRAY['Cahaya','Mitra','Karya','Sinar','Bumi','Duta','Garuda','Harapan','Indah','Jaya',
                       'Kencana','Lestari','Maju','Nusa','Prima','Sentosa','Tirta','Utama','Wahana','Surya'])[1 + floor(r_n1 * 20)::int]
       || ' ' ||
       (ARRAY['Mandiri','Abadi','Sejahtera','Perkasa','Makmur','Gemilang','Persada','Lancar','Bersama','Sukses',
              'Teknik','Pangan','Logam','Plastik','Kemasan','Otomotif','Industri','Distribusi','Kimia','Tekstil'])[1 + floor(r_n2 * 20)::int]
       || ' ' ||
       (ARRAY['Indonesia','Nusantara','Tbk','Persero','Pratama'])[1 + floor(r_n3 * 5)::int],
       (ARRAY['Manufacturing','Logistics & Warehousing','Food & Beverage','Automotive & Heavy Industry','Retail & Others'])[g],
       g::smallint,
       (ARRAY[['Electronics','Plastics & Packaging','Metal Fabrication'],
              ['3PL','Cold Chain','E-commerce Fulfillment'],
              ['Beverages','Packaged Food','Dairy'],
              ['Automotive Parts','Steel','Cement & Building Materials'],
              ['Retail Distribution','Pharmaceuticals','Others']])[g][1 + floor(r_sec * 3)::int],
       CASE WHEN r_ind < CASE flag WHEN 'CB' THEN 0.85 WHEN 'NCB' THEN 0.60 WHEN 'NEW' THEN 0.55 ELSE 0.50 END
            THEN 'Industrial Area' ELSE 'Non Industrial Area' END,
       flag,
       CASE WHEN r_org < 0.45 THEN 'Local' WHEN r_org < 0.70 THEN 'Japan' WHEN r_org < 0.80 THEN 'Korea'
            WHEN r_org < 0.90 THEN 'China' WHEN r_org < 0.96 THEN 'Europe' ELSE 'Other' END,
       br,
       (SELECT q.sales_rep_id
        FROM (SELECT sales_rep_id, row_number() OVER (ORDER BY sales_rep_id) rn, count(*) OVER () cnt
              FROM dim_sales_rep WHERE branch_code = t.br) q
        WHERE q.rn = 1 + floor(t.r_rep * q.cnt)::int),
       CASE WHEN r_site < 0.85 THEN (SELECT province FROM dim_branch WHERE branch_code = t.br)
            ELSE (ARRAY['DKI Jakarta','Jawa Barat','Banten','Jawa Tengah','Jawa Timur','Sumatera Utara',
                        'Kalimantan Timur','Sulawesi Selatan'])[1 + floor(r_site2 * 8)::int] END
FROM t;

-- 80 produk
INSERT INTO dim_product (material_code, model, product_line_code, power_type, unit_class, battery_type, capacity_ton)
WITH s AS (
    SELECT i, (ARRAY['FLE','RCH','PLT','STK','ATL','NRV'])[(i - 1) % 6 + 1] AS line,
           random() r_pw, random() r_cap, random() r_bat
    FROM generate_series(1, 80) AS i
), t AS (
    SELECT s.*, CASE WHEN line = 'FLE' AND r_pw < 0.55 THEN 'Engine' ELSE 'Electric' END AS pwr,
           pg_temp.cap_for(line, r_cap) AS cap
    FROM s
)
SELECT 'MC' || (100000 + i),
       line || '-' || to_char(cap, 'FM990.0') || CASE WHEN pwr = 'Electric' THEN 'E' ELSE 'D' END || lpad(i::text, 2, '0'),
       line, pwr,
       CASE line WHEN 'FLE' THEN CASE WHEN pwr = 'Electric' THEN 'Class 1' ELSE 'Class 4' END
                 WHEN 'RCH' THEN 'Class 2' WHEN 'NRV' THEN 'Class 2' ELSE 'Class 3' END,
       CASE WHEN pwr = 'Electric' THEN CASE WHEN r_bat < 0.6 THEN 'LIB' ELSE 'LAB' END END,
       cap
FROM t;

CREATE TEMP TABLE tmp_price ON COMMIT DROP AS
SELECT product_id,
       pg_temp.base_price(product_line_code::text, capacity_ton, power_type::text, battery_type::text) AS unit_price
FROM dim_product;

-- ---------------------------------------------------------------------
-- PARAMETERS (30 baris)
-- ---------------------------------------------------------------------

INSERT INTO ref_parameter (param_name, scope, valid_from, valid_to, param_value, description)
SELECT 'gross_margin_pct', l.product_line_code, v.vf, v.vt,
       (CASE l.product_line_code WHEN 'FLE' THEN 0.14 WHEN 'RCH' THEN 0.18 WHEN 'PLT' THEN 0.12
                                 WHEN 'STK' THEN 0.13 WHEN 'ATL' THEN 0.20 ELSE 0.22 END) + v.step,
       'Gross margin % - ' || l.product_line_name
FROM dim_product_line l
CROSS JOIN (VALUES (DATE '2023-01-01', DATE '2024-12-31', 0.00),
                   (DATE '2025-01-01', NULL::date,        0.01)) AS v(vf, vt, step);

INSERT INTO ref_parameter (param_name, scope, valid_from, valid_to, param_value, description)
SELECT 'cpo_target_multiplier', 'ALL', make_date(y, 1, 1), make_date(y, 12, 31),
       1.10 + 0.02 * (y - 2023), 'Target CPO = multiplier x sales plan, tahun ' || y
FROM generate_series(2023, 2026) AS y;

INSERT INTO ref_parameter (param_name, scope, valid_from, valid_to, param_value, description) VALUES
    ('visit_target_per_month', 'ALL', '2023-01-01', '2024-12-31', 20, 'Target kunjungan sales per bulan'),
    ('visit_target_per_month', 'ALL', '2025-01-01', NULL,         24, 'Target kunjungan sales per bulan (naik 2025)');

INSERT INTO ref_parameter (param_name, scope, valid_from, valid_to, param_value, description)
SELECT 'new_product_target_amount', l.product_line_code, make_date(y, 1, 1), make_date(y, 12, 31),
       (l.rn * 500000000 + 500000000) * (1 + 0.2 * (y - 2025)),
       'Target new product (IDR), tahun ' || y
FROM (SELECT *, row_number() OVER (ORDER BY product_line_code) AS rn FROM dim_product_line) l
CROSS JOIN generate_series(2025, 2026) AS y;

-- ---------------------------------------------------------------------
-- FACTS
-- ---------------------------------------------------------------------

-- Retail sales: 20.000 baris, ~1.5% credit note (qty & amount negatif)
INSERT INTO fact_retail_sales (bill_doc, sales_doc, billing_date, customer_id, branch_code,
                               sales_rep_id, product_id, invoiced_qty, amount, segment_type)
WITH s AS (
    SELECT i, random() r_d1, random() r_d2, random() r_c, random() r_p, random() r_q,
           random() r_cn, random() r_pr, random() r_seg, random() r_sd
    FROM generate_series(1, 20000) AS i
), t AS (
    SELECT s.i, pg_temp.rdate(s.r_d1, s.r_d2) AS billing_date,
           c.customer_id, c.branch_code, c.sales_rep_id, c.customer_base_flag,
           p.product_id, p.unit_price,
           CASE WHEN s.r_cn < 0.015 THEN -1 ELSE 1 END * (1 + floor(power(s.r_q, 3) * 3))::int AS qty,
           s.r_pr, s.r_seg, s.r_sd
    FROM s
    JOIN dim_customer c ON c.customer_id = 1 + floor(400 * power(s.r_c, 2))::int   -- customer besar = id kecil (skewed)
    JOIN tmp_price    p ON p.product_id  = 1 + floor(80  * power(s.r_p, 1.5))::int
)
SELECT 9100000000 + i,
       CASE WHEN r_sd < 0.03 THEN NULL ELSE 8100000000 + i END,
       billing_date, customer_id, branch_code, sales_rep_id, product_id, qty,
       round((unit_price * qty * (0.92 + 0.12 * r_pr))::numeric, 2),
       CASE WHEN r_seg < 0.02 THEN NULL WHEN customer_base_flag = 'NEW' THEN 'New' ELSE 'Existing' END
FROM t;

-- Sales plan: 8 cabang x 6 line x 48 bulan x 2 tipe = 4.608 baris (mengacu aktual + noise)
INSERT INTO fact_sales_plan (month_start, branch_code, product_line_code, plan_type,
                             qty_projection, amount_projection, gross_projection)
WITH act AS (
    SELECT date_trunc('month', f.billing_date)::date AS month_start, f.branch_code, p.product_line_code,
           sum(f.invoiced_qty)::numeric AS qty, sum(f.amount) AS amt
    FROM fact_retail_sales f JOIN dim_product p USING (product_id)
    GROUP BY 1, 2, 3
), avg_bl AS (
    SELECT branch_code, product_line_code, avg(amt) AS amt_avg, avg(qty) AS qty_avg
    FROM act GROUP BY 1, 2
), grid AS (
    SELECT m::date AS month_start, b.branch_code, l.product_line_code, t.plan_type, random() AS r
    FROM generate_series('2023-01-01'::date, '2026-12-01'::date, interval '1 month') AS m
    CROSS JOIN dim_branch b CROSS JOIN dim_product_line l
    CROSS JOIN (VALUES ('PLAN'), ('OUTLOOK')) AS t(plan_type)
), f AS (
    SELECT g.*, a.qty, a.amt, ab.qty_avg, ab.amt_avg,
           CASE WHEN g.plan_type = 'PLAN' THEN 0.90 + 0.35 * g.r ELSE 0.95 + 0.10 * g.r END AS factor
    FROM grid g
    LEFT JOIN act    a  ON (a.month_start, a.branch_code, a.product_line_code) = (g.month_start, g.branch_code, g.product_line_code)
    LEFT JOIN avg_bl ab ON (ab.branch_code, ab.product_line_code) = (g.branch_code, g.product_line_code)
)
SELECT f.month_start, f.branch_code, f.product_line_code, f.plan_type,
       greatest(0, round((coalesce(f.qty, f.qty_avg * 1.1, 0::numeric) * f.factor)::numeric))::int,
       round((greatest(coalesce(f.amt, f.amt_avg * 1.1, 0::numeric), 0) * f.factor)::numeric, 2),
       round((greatest(coalesce(f.amt, f.amt_avg * 1.1, 0::numeric), 0) * f.factor * gm.param_value)::numeric, 2)
FROM f
LEFT JOIN ref_parameter gm
       ON gm.param_name = 'gross_margin_pct' AND gm.scope = f.product_line_code
      AND f.month_start >= gm.valid_from AND (gm.valid_to IS NULL OR f.month_start <= gm.valid_to);

-- CPO: 8.000 baris, +-10% belum delivered (backlog)
INSERT INTO fact_cpo_order (cpo_no, cpo_date, customer_id, branch_code, sales_rep_id, product_id,
                            order_qty, amount, serial_no, status_unit, plan_delivery_date, eta_date, delivered_date)
WITH s AS (
    SELECT i, random() r_d1, random() r_d2, random() r_c, random() r_p, random() r_q, random() r_pr,
           random() r_l, random() r_an, random() r_st, random() r_eta, random() r_pl
    FROM generate_series(1, 8000) AS i
), t AS (
    SELECT s.i, pg_temp.rdate(s.r_d1, s.r_d2) AS cpo_date,
           c.customer_id, c.branch_code, c.sales_rep_id, p.product_id, p.unit_price,
           1 + floor(power(s.r_q, 4) * 5)::int AS qty,
           30 + floor(s.r_l * 91)::int AS lead,
           s.r_pr, s.r_an, s.r_st, s.r_eta, s.r_pl
    FROM s
    JOIN dim_customer c ON c.customer_id = 1 + floor(400 * power(s.r_c, 2))::int
    JOIN tmp_price    p ON p.product_id  = 1 + floor(80  * power(s.r_p, 1.5))::int
), u AS (
    SELECT t.*,
           CASE WHEN cpo_date + lead <= DATE '2026-10-19' AND r_an >= 0.01 THEN cpo_date + lead END AS delivered_date
    FROM t
), v AS (
    SELECT u.*,
           CASE WHEN delivered_date IS NOT NULL THEN 'SOH'
                WHEN r_st < 0.35 THEN 'SOO'
                WHEN r_st < 0.75 THEN 'On Vessel'
                ELSE 'SOH' END AS status_unit
    FROM u
)
SELECT 7000000000 + i, cpo_date, customer_id, branch_code, sales_rep_id, product_id, qty,
       round((unit_price * qty * (0.90 + 0.10 * r_pr))::numeric, 2),
       CASE WHEN status_unit = 'SOO' THEN NULL ELSE 'SN' || lpad(i::text, 8, '0') END,
       status_unit,
       cpo_date + 45 + floor(r_pl * 60)::int,
       CASE WHEN status_unit = 'On Vessel' THEN DATE '2026-10-19' + (3 + floor(r_eta * 45))::int
            WHEN delivered_date IS NOT NULL THEN delivered_date - 7 END,
       delivered_date
FROM v;

-- Stock pipeline: 1.500 unit (order 240 hari terakhir)
INSERT INTO fact_stock_pipeline (serial_no, product_id, sales_rep_id, pipeline_status,
                                 order_date, received_date, expected_lead_time_days)
WITH s AS (
    SELECT i, random() r_p, random() r_rep, random() r_nr, random() r_o, random() r_lt, random() r_rv
    FROM generate_series(1, 1500) AS i
), t AS (
    SELECT s.*, DATE '2026-10-19' - floor(r_o * 240)::int AS order_date,
           30 + floor(r_lt * 121)::int AS lead
    FROM s
), u AS (
    SELECT t.*, order_date + round(lead * (0.85 + 0.55 * r_rv))::int AS rcv_date FROM t
)
SELECT 'SP' || lpad(i::text, 8, '0'),
       1 + floor(r_p * 80)::int,
       CASE WHEN r_nr < 0.05 THEN NULL ELSE 1 + floor(r_rep * 30)::int END,
       CASE WHEN rcv_date <= DATE '2026-10-19' THEN 'SOH'
            WHEN DATE '2026-10-19' - order_date >= lead * 0.5 THEN 'On Vessel'
            ELSE 'SOO' END,
       order_date,
       CASE WHEN rcv_date <= DATE '2026-10-19' THEN rcv_date END,
       lead
FROM u;

-- Opportunity: 3.000 baris (status tergantung umur opportunity)
INSERT INTO fact_opportunity (created_date, branch_code, customer_id, sales_rep_id, product_id, qty, amount,
                              status, activity_stage, plan_po_month, last_update, next_action)
WITH s AS (
    SELECT i, random() r_d1, random() r_d2, random() r_c, random() r_p, random() r_q, random() r_pr,
           random() r_an, random() r_st, random() r_st2, random() r_po, random() r_lu, random() r_na
    FROM generate_series(1, 3000) AS i
), t AS (
    SELECT s.*, pg_temp.rdate(s.r_d1, s.r_d2) AS created_date,
           c.customer_id, c.branch_code, c.sales_rep_id, p.product_id, p.unit_price
    FROM s
    JOIN dim_customer c ON c.customer_id = 1 + floor(400 * power(s.r_c, 2))::int
    JOIN tmp_price    p ON p.product_id  = 1 + floor(80  * power(s.r_p, 1.2))::int
), u AS (
    SELECT t.*, 1 + floor(power(r_q, 2) * 5)::int AS q2,
           CASE
             WHEN DATE '2026-10-19' - created_date > 150 THEN
                  CASE WHEN r_st < 0.35 THEN 'Won' WHEN r_st < 0.65 THEN 'Lost' WHEN r_st < 0.85 THEN 'Closed'
                       WHEN r_st < 0.95 THEN 'Cold' WHEN r_st < 0.99 THEN 'Warm' ELSE 'Hot' END
             WHEN DATE '2026-10-19' - created_date >= 60 THEN
                  CASE WHEN r_st < 0.25 THEN 'Won' WHEN r_st < 0.45 THEN 'Lost' WHEN r_st < 0.55 THEN 'Closed'
                       WHEN r_st < 0.70 THEN 'Cold' WHEN r_st < 0.90 THEN 'Warm' ELSE 'Hot' END
             ELSE
                  CASE WHEN r_st < 0.08 THEN 'Won' WHEN r_st < 0.13 THEN 'Lost' WHEN r_st < 0.15 THEN 'Closed'
                       WHEN r_st < 0.45 THEN 'Cold' WHEN r_st < 0.75 THEN 'Warm' ELSE 'Hot' END
           END AS status
    FROM t
)
SELECT created_date, branch_code, customer_id, sales_rep_id, product_id, q2,
       CASE WHEN r_an < 0.03 THEN NULL ELSE round((unit_price * q2 * (0.90 + 0.15 * r_pr))::numeric, 2) END,
       status,
       CASE status
            WHEN 'Won'    THEN 'Won'
            WHEN 'Lost'   THEN 'Lost'
            WHEN 'Closed' THEN 'Hold'
            WHEN 'Cold'   THEN CASE WHEN r_st2 < 0.5 THEN 'Planning a Promotion' ELSE 'Product Demo' END
            WHEN 'Warm'   THEN CASE WHEN r_st2 < 0.6 THEN 'Sent Quotation' ELSE 'Product Demo' END
            ELSE               CASE WHEN r_st2 < 0.8 THEN 'Under Customer Review' ELSE 'Sent Quotation' END
       END,
       date_trunc('month', created_date + (30 + floor(r_po * 150))::int)::date,
       LEAST(DATE '2026-10-19', created_date + floor(r_lu * 60)::int),
       CASE WHEN status IN ('Cold', 'Warm', 'Hot')
            THEN (ARRAY['Kirim ulang quotation','Jadwalkan demo unit','Follow up keputusan manajemen',
                        'Negosiasi harga dan payment term','Kunjungan ke site customer','Minta approval budget'])[1 + floor(r_na * 6)::int]
       END
FROM u;

-- Lost deal: 600 baris, kompetitor lebih murah 5-20% (8% harga kompetitor kosong)
INSERT INTO fact_lost_deal (lost_date, sales_rep_id, customer_id, branch_code, product_id, qty,
                            our_unit_price, competitor_brand_code, competitor_unit_price,
                            lost_reason, lost_description, prospect_date, quotation_date)
WITH s AS (
    SELECT i, random() r_d1, random() r_d2, random() r_c, random() r_p, random() r_q, random() r_pr,
           random() r_cb, random() r_gap, random() r_nc, random() r_lr, random() r_a, random() r_b,
           random() r_np, random() r_nq
    FROM generate_series(1, 600) AS i
), t AS (
    SELECT s.*, pg_temp.rdate(s.r_d1, s.r_d2) AS lost_date,
           c.customer_id, c.branch_code, c.sales_rep_id, p.product_id, p.unit_price,
           CASE WHEN r_lr < 0.50 THEN 'Price' WHEN r_lr < 0.65 THEN 'Lead Time' WHEN r_lr < 0.77 THEN 'Brand Preference'
                WHEN r_lr < 0.87 THEN 'Payment Terms' WHEN r_lr < 0.95 THEN 'Spec Mismatch'
                ELSE 'After Sales Service' END AS reason,
           round((p.unit_price * (0.95 + 0.10 * r_pr))::numeric, 2) AS our_price,
           lost_q.q AS q2
    FROM s
    JOIN dim_customer c ON c.customer_id = 1 + floor(400 * power(s.r_c, 2))::int
    JOIN tmp_price    p ON p.product_id  = 1 + floor(80  * power(s.r_p, 1.2))::int
    CROSS JOIN LATERAL (SELECT 1 + floor(power(s.r_q, 2) * 3)::int AS q) lost_q
)
SELECT lost_date, sales_rep_id, customer_id, branch_code, product_id, q2, our_price,
       (ARRAY['HKT','KNZ','SRL','DRG','HNB','EUL','NRD','BLR'])[1 + floor(r_cb * 8)::int],
       CASE WHEN r_nc < 0.08 THEN NULL ELSE round((our_price * (0.80 + 0.15 * r_gap))::numeric, 2) END,
       reason,
       CASE reason
            WHEN 'Price'               THEN 'Kompetitor menawarkan harga unit lebih rendah'
            WHEN 'Lead Time'           THEN 'Waktu pengiriman kompetitor lebih cepat'
            WHEN 'Brand Preference'    THEN 'Customer sudah memakai brand kompetitor di site'
            WHEN 'Payment Terms'       THEN 'Kompetitor memberi termin pembayaran lebih panjang'
            WHEN 'Spec Mismatch'      THEN 'Spesifikasi unit tidak sesuai kebutuhan operasional'
            ELSE                            'Layanan purna jual dinilai kurang memadai'
       END,
       CASE WHEN r_np < 0.10 THEN NULL ELSE lost_date - (5 + floor(r_a * 50))::int - (5 + floor(r_b * 60))::int END,
       CASE WHEN r_nq < 0.05 THEN NULL ELSE lost_date - (5 + floor(r_a * 50))::int END
FROM t;

-- UIO: customer x brand x 2023-2026 (+-4.000 baris)
INSERT INTO fact_uio (customer_id, brand_code, year, uio_count)
WITH pairs AS (
    SELECT c.customer_id, b.brand_code, random() AS r_pick, random() AS r_base
    FROM dim_customer c CROSS JOIN dim_brand b
), picked AS (
    SELECT customer_id, brand_code, 1 + floor(power(r_base, 2) * 8)::int AS base_cnt
    FROM pairs
    WHERE r_pick < 0.06 + 0.36 * power(1 - (customer_id - 1) / 400.0, 1.2)
)
SELECT customer_id, brand_code, y,
       greatest(0, round(base_cnt * (1 + 0.06 * (y - 2023)) + (random() * 2 - 1))::int)
FROM picked CROSS JOIN generate_series(2023, 2026) AS y;

-- Import: 10.000 baris, bobot brand + origin + kurs per tahun
CREATE TEMP TABLE tmp_brand ON COMMIT DROP AS
SELECT v.brand_code, v.country, v.port, v.factor,
       coalesce(sum(v.w) OVER (ORDER BY v.ord ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS lo,
       sum(v.w) OVER (ORDER BY v.ord) AS hi
FROM (VALUES
    (1,  'MRD', 'Japan',    'Yokohama',      1.00, 0.15),
    (2,  'MRL', 'China',    'Shanghai',      0.75, 0.08),
    (3,  'MRX', 'Japan',    'Nagoya',        1.00, 0.07),
    (4,  'MRE', 'China',    'Ningbo',        0.75, 0.05),
    (5,  'HKT', 'Japan',    'Yokohama',      1.00, 0.18),
    (6,  'KNZ', 'Japan',    'Kobe',          0.95, 0.12),
    (7,  'SRL', 'China',    'Shanghai',      0.70, 0.08),
    (8,  'DRG', 'China',    'Qingdao',       0.70, 0.08),
    (9,  'HNB', 'Korea',    'Busan',         0.90, 0.07),
    (10, 'EUL', 'Germany',  'Hamburg',       1.20, 0.06),
    (11, 'NRD', 'Sweden',   'Gothenburg',    1.20, 0.03),
    (12, 'BLR', 'Thailand', 'Laem Chabang',  0.80, 0.03)
) AS v(ord, brand_code, country, port, factor, w);

INSERT INTO fact_import (declaration_no, declaration_date, brand_code, origin_country, supplier_name,
                         supplier_port, arrival_port, importer_name, hs_code, goods_description, goods_type,
                         unit_class, classification, capacity_ton, qty, net_weight_kg, value_idr, value_usd)
WITH s AS (
    SELECT i, random() r_d1, random() r_d2, random() r_b, random() r_l, random() r_cap, random() r_pw,
           random() r_q, random() r_pr, random() r_imp, random() r_port, random() r_gt, random() r_fx, random() r_wt
    FROM generate_series(1, 10000) AS i
), t AS (
    SELECT s.*, pg_temp.rdate(s.r_d1, s.r_d2) AS decl_date,
           tb.brand_code, tb.country, tb.port, tb.factor, b.brand_name, b.brand_type,
           CASE WHEN r_l < 0.45 THEN 'FLE' WHEN r_l < 0.55 THEN 'RCH' WHEN r_l < 0.80 THEN 'PLT'
                WHEN r_l < 0.90 THEN 'STK' WHEN r_l < 0.94 THEN 'ATL' ELSE 'NRV' END AS line
    FROM s
    JOIN tmp_brand tb ON s.r_b >= tb.lo AND s.r_b < tb.hi
    JOIN dim_brand b  ON b.brand_code = tb.brand_code
), u AS (
    SELECT t.*, pg_temp.cap_for(line, r_cap) AS cap,
           CASE WHEN line = 'FLE' AND r_pw < 0.55 THEN 'Engine' ELSE 'Electric' END AS pwr,
           1 + floor(power(r_q, 3) * 20)::int AS q2,
           pl.product_line_name
    FROM t JOIN dim_product_line pl ON pl.product_line_code = t.line
)
SELECT 'DCL' || lpad(i::text, 9, '0'),
       decl_date, brand_code, country,
       brand_name || ' Manufacturing Co.',
       port,
       CASE WHEN r_port < 0.60 THEN 'Tanjung Priok' WHEN r_port < 0.85 THEN 'Tanjung Perak'
            WHEN r_port < 0.93 THEN 'Tanjung Emas' ELSE 'Belawan' END,
       CASE WHEN brand_type = 'Own Brand' THEN 'PT Meridian Material Handling'
            WHEN r_imp < 0.70 THEN 'PT ' || brand_name || ' Indonesia'
            ELSE (ARRAY['PT Karya Alat Berat','PT Sinar Logistik Mandiri','PT Nusa Lift Perkasa','PT Prima Handling Utama'])
                 [1 + floor((r_imp - 0.70) / 0.30 * 4)::int] END,
       CASE line WHEN 'FLE' THEN CASE WHEN pwr = 'Electric' THEN '8427.10' ELSE '8427.20' END
                 WHEN 'RCH' THEN '8427.10' WHEN 'NRV' THEN '8427.10'
                 WHEN 'ATL' THEN '8709.11' ELSE '8427.90' END,
       upper(product_line_name || ' ' || pwr || ' ' || to_char(cap, 'FM990.0') || ' TON ' || brand_name),
       CASE WHEN r_gt < 0.88 THEN 'Complete Unit' WHEN r_gt < 0.96 THEN 'CKD' ELSE 'Used Unit' END,
       CASE line WHEN 'FLE' THEN CASE WHEN pwr = 'Electric' THEN 'Class 1' ELSE 'Class 4' END
                 WHEN 'RCH' THEN 'Class 2' WHEN 'NRV' THEN 'Class 2' ELSE 'Class 3' END,
       left(product_line_name, 30),
       cap, q2,
       round((q2 * (1200 + 700 * cap) * (0.9 + 0.2 * r_wt))::numeric, 2),
       round((q2 * pg_temp.base_price(line, cap, pwr, 'LAB') * 0.65 * factor * (0.90 + 0.20 * r_pr))::numeric, 2),
       round(((q2 * pg_temp.base_price(line, cap, pwr, 'LAB') * 0.65 * factor * (0.90 + 0.20 * r_pr))
              / (15400 + 350 * (EXTRACT(YEAR FROM decl_date)::int - 2023) + 200 * r_fx))::numeric, 2)
FROM u;

-- ---------------------------------------------------------------------
-- CLEANUP + ANALYZE
-- ---------------------------------------------------------------------
DROP FUNCTION pg_temp.rdate(float8, float8);
DROP FUNCTION pg_temp.cap_for(text, float8);
DROP FUNCTION pg_temp.base_price(text, numeric, text, text);

COMMIT;

ANALYZE;

-- ---------------------------------------------------------------------
-- CEK HASIL
-- ---------------------------------------------------------------------
SELECT 'dim_branch' AS tbl, count(*) AS n FROM mart.dim_branch
UNION ALL SELECT 'dim_product_line',    count(*) FROM mart.dim_product_line
UNION ALL SELECT 'dim_sales_rep',       count(*) FROM mart.dim_sales_rep
UNION ALL SELECT 'dim_customer',        count(*) FROM mart.dim_customer
UNION ALL SELECT 'dim_brand',           count(*) FROM mart.dim_brand
UNION ALL SELECT 'dim_product',         count(*) FROM mart.dim_product
UNION ALL SELECT 'fact_retail_sales',   count(*) FROM mart.fact_retail_sales
UNION ALL SELECT 'fact_sales_plan',     count(*) FROM mart.fact_sales_plan
UNION ALL SELECT 'fact_cpo_order',      count(*) FROM mart.fact_cpo_order
UNION ALL SELECT 'fact_stock_pipeline', count(*) FROM mart.fact_stock_pipeline
UNION ALL SELECT 'fact_opportunity',    count(*) FROM mart.fact_opportunity
UNION ALL SELECT 'fact_lost_deal',      count(*) FROM mart.fact_lost_deal
UNION ALL SELECT 'fact_uio',            count(*) FROM mart.fact_uio
UNION ALL SELECT 'fact_import',         count(*) FROM mart.fact_import
UNION ALL SELECT 'ref_parameter',       count(*) FROM mart.ref_parameter;
