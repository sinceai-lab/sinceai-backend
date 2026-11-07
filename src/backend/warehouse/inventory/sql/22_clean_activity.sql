-- Waste notes: a monthly quantity 100x below the stream's usual level is tonnes keyed as kg.
CREATE TABLE clean.waste AS
SELECT *, 'waste:' || transfer_note AS record_key,
       quantity < 0.01 * median(quantity) OVER (PARTITION BY site_id, waste_stream) AS is_unit_error,
       quantity * CASE WHEN is_unit_error THEN 1000 ELSE 1 END / 1000 AS t,
       CASE WHEN waste_stream = 'plastic_waste' THEN 'EF-WASTE-PLASTIC-INC'
            ELSE CASE treatment WHEN 'anaerobic_digestion' THEN 'EF-WASTE-BIO-AD'
                                WHEN 'composting' THEN 'EF-WASTE-BIO-COMPOST'
                                WHEN 'incineration' THEN 'EF-WASTE-MIXED-INC'
                                WHEN 'recycling' THEN 'EF-WASTE-RECYCLE'
                                WHEN 'landfill_codigestion' THEN 'EF-WASTE-SPENTEARTH' END END AS ef_id
FROM raw.waste_transfer_notes;

INSERT INTO dq.issue (rule_id, source_table, record_key, issue_type, year, field, observed, applied, action, confidence, explanation, source_file, source_row)
SELECT 'WASTE-UNIT', 'waste_transfer_notes', record_key, 'unit_error', year, 'quantity', quantity::VARCHAR, (t * 1000)::VARCHAR, 'corrected', 'high',
       'Under 1 % of the stream''s usual month: tonnes keyed as kg', _source_file, _source_row
FROM clean.waste WHERE is_unit_error;

-- Travel: the duplicate definition comes from TASKS_AND_SCORING.md.
CREATE TABLE clean.travel AS
SELECT *, 'travel:' || booking_id AS record_key,
       row_number() OVER (PARTITION BY traveller_id, travel_date, route, pkm, nights ORDER BY _source_row) > 1 AS is_duplicate
FROM raw.travel_bookings;

INSERT INTO dq.issue (rule_id, source_table, record_key, issue_type, year, field, observed, applied, action, confidence, explanation, source_file, source_row)
SELECT 'TRAVEL-DUP', 'travel_bookings', record_key, 'duplicate_record', year, '*', booking_id, NULL, 'excluded', 'high',
       'Same traveller, date, route, distance and nights as an earlier row', _source_file, _source_row
FROM clean.travel WHERE is_duplicate;

-- Commuting: distances over 1,000 km one way are metres; Finnish and mixed-case
-- mode names map onto the survey's own codes.
CREATE TABLE clean.commuting AS
SELECT *, 'commute:' || response_id AS record_key,
       one_way_km > 1000 AS is_unit_error,
       one_way_km / CASE WHEN is_unit_error THEN 1000 ELSE 1 END AS one_way_km_clean,
       CASE lower(mode) WHEN 'henkilöauto' THEN 'car' WHEN 'auto' THEN 'car' WHEN 'linja-auto' THEN 'bus'
                        ELSE lower(mode) END AS mode_clean
FROM raw.commuting_survey_2025;

INSERT INTO dq.issue (rule_id, source_table, record_key, issue_type, year, field, observed, applied, action, confidence, explanation, source_file, source_row)
SELECT 'COMMUTE-UNIT', 'commuting_survey', record_key, 'unit_error', 2025, 'one_way_km', one_way_km::VARCHAR, one_way_km_clean::VARCHAR, 'corrected', 'high',
       'Over 1,000 km one way: metres entered as km', _source_file, _source_row
FROM clean.commuting WHERE is_unit_error
UNION ALL
SELECT 'COMMUTE-MODE', 'commuting_survey', record_key, 'mode_mislabel', 2025, 'mode', mode, mode_clean, 'corrected', 'high',
       'Mode label is not one of the survey codes', _source_file, _source_row
FROM clean.commuting WHERE mode <> mode_clean;

-- Shipments: an import lot's legs follow its material and origin. A lot missing a
-- leg that nearly all its peers have gets that leg, with the peers' median distance.
CREATE TABLE clean.shipment AS
WITH doc AS (
    SELECT doc_no, any_value(material_id_clean) AS material_id, any_value(origin_country) AS origin_country
    FROM clean.erp WHERE movement_type = 101 GROUP BY 1
),
legs AS (
    SELECT s.*, d.material_id, d.origin_country
    FROM raw.shipments s JOIN doc d ON d.doc_no = s.ref_doc WHERE s.direction = 'inbound'
),
docs AS (SELECT DISTINCT ref_doc, year, material_id, origin_country FROM legs),
peer_size AS (SELECT material_id, origin_country, count(*) AS docs FROM docs GROUP BY 1, 2),
peer_leg AS (
    SELECT material_id, origin_country, ef_id, any_value(mode) AS mode, count(DISTINCT ref_doc) AS docs, median(km) AS km
    FROM legs GROUP BY 1, 2, 3
),
expected AS (
    SELECT d.ref_doc, d.year, l.ef_id, l.mode, l.km
    FROM docs d JOIN peer_size p USING (material_id, origin_country)
    JOIN peer_leg l USING (material_id, origin_country)
    WHERE l.docs >= 0.8 * p.docs
),
absent AS (
    SELECT e.* FROM expected e
    LEFT JOIN legs x ON x.ref_doc = e.ref_doc AND x.ef_id = e.ef_id WHERE x.ref_doc IS NULL
),
lot_weight AS (SELECT ref_doc, max(t) AS t FROM legs GROUP BY 1)
SELECT shipment_id, year, direction, ref_doc, ef_id, mode, t, km, tkm, false AS is_estimated,
       'ship:' || ref_doc || ':' || ef_id AS record_key, _source_file, _source_row
FROM raw.shipments
UNION ALL
SELECT NULL, a.year, 'inbound', a.ref_doc, a.ef_id, a.mode, w.t, a.km, w.t * a.km, true,
       'ship:' || a.ref_doc || ':' || a.ef_id, NULL, NULL
FROM absent a JOIN lot_weight w USING (ref_doc);

INSERT INTO dq.issue (rule_id, source_table, record_key, issue_type, year, field, observed, applied, action, confidence, explanation, source_file, source_row)
SELECT 'SHIP-LEG', 'shipments', record_key, 'missing_leg', year, 'tkm', NULL, tkm::VARCHAR, 'estimated', 'medium',
       'Leg present on nearly all lots of this material and origin; added at the peers'' median distance', NULL, NULL
FROM clean.shipment WHERE is_estimated;

-- Supplier PCFs: valid only if the reference period covers the year and the value is
-- per kg. Invalid PCFs are not repaired; the method falls back to the default factor.
CREATE TABLE clean.pcf AS
SELECT p.*, 'pcf:' || supplier_id || ':' || p.material_id || ':' || year AS record_key,
       f.kgco2e_per_unit AS default_factor,
       NOT (year(reference_period_start_utc) <= year AND reference_period_end_utc > make_date(year, 1, 1)) AS is_stale,
       declared_unit <> 'kilogram' OR pcf_excluding_biogenic > 100 * f.kgco2e_per_unit AS is_unit_error,
       NOT is_stale AND NOT is_unit_error AS is_valid
FROM raw.supplier_pcfs p
JOIN raw.materials m USING (material_id)
JOIN raw.emission_factor_library f ON f.ef_id = m.default_ef_id;

INSERT INTO dq.issue (rule_id, source_table, record_key, issue_type, year, field, observed, applied, action, confidence, explanation, source_file, source_row)
SELECT 'PCF-UNIT', 'supplier_pcfs', record_key, 'pcf_unit_error', year, 'pCfExcludingBiogenic', pcf_excluding_biogenic::VARCHAR, default_factor::VARCHAR, 'excluded', 'high',
       'Over 100x the default factor: not per kg, so the default factor is used', _source_file, _source_row
FROM clean.pcf WHERE is_unit_error
UNION ALL
SELECT 'PCF-STALE', 'supplier_pcfs', record_key, 'pcf_stale_period', year, 'referencePeriodStart', reference_period_start_utc::VARCHAR, default_factor::VARCHAR, 'excluded', 'high',
       'Reference period does not cover the year, so the default factor is used', _source_file, _source_row
FROM clean.pcf WHERE is_stale;
