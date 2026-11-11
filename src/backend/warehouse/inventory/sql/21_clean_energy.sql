-- Monthly meters. Seasonal peaks are legitimate, so readings are judged against the
-- same month in other years (relative to each year's median), never a flat average.
CREATE TABLE clean.energy_meter AS
WITH unit_fixed AS (
    SELECT *,
           'energy:' || site_id || ':' || year || '-' || lpad(month::VARCHAR, 2, '0') || ':' || carrier AS record_key,
           value > 200 * median(value) OVER (PARTITION BY site_id, carrier, year)
               AND median(value) OVER (PARTITION BY site_id, carrier, year) > 0 AS is_unit_error
    FROM raw.energy_meter_readings
),
scaled AS (
    SELECT *, CASE WHEN is_unit_error THEN value / 1000 ELSE value END AS value_1 FROM unit_fixed
),
relative AS (
    SELECT *, median(value_1) OVER (PARTITION BY site_id, carrier, year) AS year_median FROM scaled
),
seasonal AS (
    SELECT *, median(value_1 / nullif(year_median, 0)) OVER (PARTITION BY site_id, carrier, month) AS month_index
    FROM relative
),
readings AS (
    SELECT *, year_median > 0 AND value_1 / year_median > 2.4 * month_index AS is_spike FROM seasonal
),
series AS (
    SELECT site_id, carrier, min(make_date(year, month, 1)) AS first_month, max(make_date(year, month, 1)) AS last_month
    FROM raw.energy_meter_readings GROUP BY 1, 2
),
expected AS (
    SELECT site_id, carrier, unnest(generate_series(first_month, last_month, INTERVAL 1 MONTH))::DATE AS m FROM series
),
missing AS (
    SELECT x.site_id, x.carrier, year(x.m) AS year, month(x.m) AS month
    FROM expected x
    LEFT JOIN raw.energy_meter_readings r ON r.site_id = x.site_id AND r.carrier = x.carrier
         AND r.year = year(x.m) AND r.month = month(x.m)
    WHERE r.site_id IS NULL
),
month_level AS (SELECT DISTINCT site_id, carrier, month, month_index FROM readings),
-- A year's level uses all its sound months, which is steadier than one median for a
-- seasonal series. Estimate for a month = level x that month's seasonal index.
year_level AS (
    SELECT site_id, carrier, year, sum(value_1) / nullif(sum(month_index), 0) AS level
    FROM readings WHERE NOT coalesce(is_spike, false) GROUP BY 1, 2, 3
)
SELECT site_id, year, month, carrier, record_key, value AS value_raw,
       CASE WHEN is_spike THEN y.level * month_index ELSE value_1 END AS mwh,
       is_unit_error, is_spike, false AS is_missing, _source_file, _source_row
FROM readings r
JOIN year_level y USING (site_id, carrier, year)
UNION ALL
SELECT m.site_id, m.year, m.month, m.carrier,
       'energy:' || m.site_id || ':' || m.year || '-' || lpad(m.month::VARCHAR, 2, '0') || ':' || m.carrier,
       NULL, y.level * i.month_index, false, false, true, NULL, NULL
FROM missing m
JOIN year_level y USING (site_id, carrier, year)
JOIN month_level i USING (site_id, carrier, month);

INSERT INTO dq.issue (rule_id, source_table, record_key, issue_type, year, field, observed, applied, action, confidence, explanation, source_file, source_row)
SELECT 'METER-UNIT', 'energy_meter_readings', record_key, 'unit_error', year, 'value', value_raw::VARCHAR, (value_raw / 1000)::VARCHAR, 'corrected', 'high',
       'Over 200x the year median: kWh reported in the MWh column', _source_file, _source_row
FROM clean.energy_meter WHERE is_unit_error
UNION ALL
SELECT 'METER-SPIKE', 'energy_meter_readings', record_key, 'meter_spike', year, 'value', value_raw::VARCHAR, mwh::VARCHAR, 'estimated', 'medium',
       'Over 2.4x the normal level for this month; replaced with the seasonal estimate', _source_file, _source_row
FROM clean.energy_meter WHERE is_spike
UNION ALL
SELECT 'METER-GAP', 'energy_meter_readings', record_key, 'missing_record', year, 'value', NULL, mwh::VARCHAR, 'estimated', 'medium',
       'Month missing inside the meter series; filled with the seasonal estimate', NULL, NULL
FROM clean.energy_meter WHERE is_missing;

-- Fuel deliveries in litres: a load 100x below normal is m3 keyed as litres.
CREATE TABLE clean.fuel_delivery AS
SELECT *, 'fuel:' || delivery_id AS record_key,
       unit = 'l' AND quantity < 0.01 * median(quantity) OVER (PARTITION BY site_id, carrier) AS is_unit_error,
       quantity * CASE WHEN is_unit_error THEN 1000 ELSE 1 END AS quantity_clean
FROM raw.fuel_deliveries;

INSERT INTO dq.issue (rule_id, source_table, record_key, issue_type, year, field, observed, applied, action, confidence, explanation, source_file, source_row)
SELECT 'FUEL-UNIT', 'fuel_deliveries', record_key, 'unit_error', year, 'quantity', quantity::VARCHAR, quantity_clean::VARCHAR, 'corrected', 'high',
       'Under 1 % of the usual delivery: m3 keyed as litres', _source_file, _source_row
FROM clean.fuel_delivery WHERE is_unit_error;

-- Refrigerants: a system holds one gas. Genuine top-ups stay within about 5x a system's
-- median, so 20x marks grams in the kg column. Ammonia is excluded: it has no GWP, and
-- large ammonia top-ups are normal.
CREATE TABLE clean.refrigerant AS
WITH system_gas AS (
    SELECT site_id, system, mode(refrigerant) AS gas, median(kg_added) AS median_kg
    FROM raw.refrigerant_service_log GROUP BY 1, 2
)
SELECT r.*, 'refrigerant:' || event_id AS record_key, s.gas AS refrigerant_clean,
       r.refrigerant <> s.gas AS is_wrong_gas,
       r.kg_added > 20 * s.median_kg AND s.gas <> 'R717_ammonia' AS is_unit_error,
       r.kg_added / CASE WHEN is_unit_error THEN 1000 ELSE 1 END AS kg_clean
FROM raw.refrigerant_service_log r JOIN system_gas s USING (site_id, system);

INSERT INTO dq.issue (rule_id, source_table, record_key, issue_type, year, field, observed, applied, action, confidence, explanation, source_file, source_row)
SELECT 'REFRIG-GAS', 'refrigerant_service_log', record_key, 'wrong_gas_code', year, 'refrigerant', refrigerant, refrigerant_clean, 'corrected', 'medium',
       'Gas code differs from what this system otherwise uses', _source_file, _source_row
FROM clean.refrigerant WHERE is_wrong_gas
UNION ALL
SELECT 'REFRIG-UNIT', 'refrigerant_service_log', record_key, 'unit_error', year, 'kg_added', kg_added::VARCHAR, kg_clean::VARCHAR, 'corrected', 'high',
       'Over 20x the usual top-up: grams in the kg column', _source_file, _source_row
FROM clean.refrigerant WHERE is_unit_error;

-- Guarantees of origin: the registry is authoritative, and only a certificate
-- produced in the consumption year counts. The internal log is only compared to it.
CREATE TABLE clean.goo AS
SELECT *, year(production_period_end) = consumption_year AND year(production_period_start) = consumption_year AS is_valid
FROM raw.goo_registry_statement;

INSERT INTO dq.issue (rule_id, source_table, record_key, issue_type, year, field, observed, applied, action, confidence, explanation, source_file, source_row)
WITH registry AS (
    SELECT beneficiary_site AS site_id, consumption_year AS year, sum(mwh) AS mwh, max(year(production_period_end)) AS vintage
    FROM clean.goo WHERE is_valid GROUP BY 1, 2
)
SELECT 'GOO-LOG', 'goo_cancellations', 'goo:' || g.site_id || ':' || g.year, 'certificate_mismatch', g.year,
       CASE WHEN g.vintage_year <> r.vintage THEN 'vintage_year' ELSE 'mwh_cancelled' END,
       CASE WHEN g.vintage_year <> r.vintage THEN g.vintage_year::VARCHAR ELSE g.mwh_cancelled::VARCHAR END,
       CASE WHEN g.vintage_year <> r.vintage THEN r.vintage::VARCHAR ELSE r.mwh::VARCHAR END,
       'corrected', 'high', 'Internal log disagrees with the registry statement; registry used', g._source_file, g._source_row
FROM raw.goo_cancellations g LEFT JOIN registry r USING (site_id, year)
WHERE r.site_id IS NULL OR g.vintage_year <> r.vintage OR abs(g.mwh_cancelled - r.mwh) > 1;
