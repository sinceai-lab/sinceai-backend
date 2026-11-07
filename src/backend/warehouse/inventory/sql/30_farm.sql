-- Contract-farm footprints (METHODOLOGY.md section 5), per farm, crop and year.
CREATE TABLE ref.contract_crop AS
SELECT * FROM (VALUES ('M100', 'turnip_rape'), ('M110', 'pea'), ('M111', 'potato'),
                      ('M112', 'carrot'), ('M113', 'spinach')) t(material_id, crop);

-- Organic soil is the largest single driver of farm emissions, and the soil map is
-- only ~88 % accurate. clay_pct is measured separately from the class, so a parcel
-- mapped "clay" with little clay is a map error. On a farm with organic evidence (a
-- farmer's report in any year, or 30 %+ organic on the map) it counts as organic.
-- Silt and sand overlap organic soil on clay content, so they stay as mapped.
CREATE TABLE clean.parcel_soil AS
WITH evidence AS (
    SELECT p.farm_id,
           sum(p.area_ha) FILTER (WHERE p.soil_class_soilmap = 'organic') / sum(p.area_ha) AS organic_share_map,
           any_value(r.farm_id) IS NOT NULL AS reported_organic
    FROM raw.parcels p
    LEFT JOIN (SELECT DISTINCT farm_id FROM raw.farm_survey_fi WHERE soil_type_reported = 'Organic soil') r USING (farm_id)
    GROUP BY 1
)
SELECT p.parcel_id, p.farm_id, p.area_ha, p.soil_class_soilmap, p.clay_pct_soilmap,
       p.soil_class_soilmap = 'organic' AS is_organic_map,
       p.soil_class_soilmap = 'clay' AND p.clay_pct_soilmap < 25
           AND (e.reported_organic OR coalesce(e.organic_share_map, 0) >= 0.3) AS is_reclassified,
       is_organic_map OR is_reclassified AS is_organic,
       p._source_file, p._source_row
FROM raw.parcels p JOIN evidence e USING (farm_id);

INSERT INTO dq.issue (rule_id, source_table, record_key, issue_type, year, field, observed, applied, action, confidence, explanation, source_file, source_row)
SELECT 'SOIL-CLAY', 'parcels', 'parcel:' || parcel_id, 'soil_map_conflict', NULL, 'soil_class_soilmap', soil_class_soilmap, 'organic', 'estimated', 'medium',
       'Mapped clay with ' || clay_pct_soilmap || ' % clay, on a farm with organic soil evidence', _source_file, _source_row
FROM clean.parcel_soil WHERE is_reclassified;

-- Parcels are the register of what was grown where. Area comes from here, not the survey.
CREATE TABLE clean.farm_area AS
SELECT h.farm_id, h.crop, h.year,
       sum(p.area_ha) AS area_ha,
       coalesce(sum(p.area_ha) FILTER (WHERE p.is_organic), 0) AS organic_ha,
       coalesce(sum(p.area_ha) FILTER (WHERE p.is_organic_map), 0) AS organic_ha_map
FROM raw.parcel_crop_history_and_plan h JOIN clean.parcel_soil p USING (parcel_id)
GROUP BY 1, 2, 3;

CREATE TABLE clean.farm_delivery AS
SELECT e.supplier_id AS farm_id, c.crop, e.year, sum(e.qty_kg) AS delivered_kg
FROM clean.erp e JOIN ref.contract_crop c ON c.material_id = e.material_id_clean
WHERE NOT e.is_duplicate
GROUP BY 1, 2, 3;

CREATE TABLE clean.farm_survey AS
WITH typical AS (
    SELECT crop, year, median(n_mineral_kg_ha) FILTER (WHERE n_mineral_kg_ha > 0) AS median_n
    FROM raw.farm_survey_fi GROUP BY 1, 2
)
SELECT s.*, 'farm_survey:' || s.survey_id AS record_key,
       a.area_ha AS area_ha_parcels,
       a.organic_ha / a.area_ha AS organic_share,
       d.delivered_kg / 1000 / a.area_ha AS delivered_t_ha,
       s.n_mineral_kg_ha > 0 AND (s.n_mineral_kg_ha < 0.2 * t.median_n OR s.n_mineral_kg_ha > 5 * t.median_n) AS is_n_shift,
       s.n_mineral_kg_ha * CASE WHEN NOT is_n_shift THEN 1
                                WHEN s.n_mineral_kg_ha < t.median_n THEN 10 ELSE 0.1 END AS n_mineral_clean,
       s.yield_t_ha > 3 * delivered_t_ha AS is_yield_outlier,
       s.yield_t_ha * CASE WHEN is_yield_outlier THEN 0.1 ELSE 1 END AS yield_clean,
       abs(s.area_ha / a.area_ha - 1) > 0.05 AS is_area_mismatch,
       s.soil_type_reported = 'Mineral soil' AND organic_share >= 0.3 AS is_soil_misreport,
       coalesce(s.fertiliser_product LIKE '%low-carbon%', false) AS low_carbon
FROM raw.farm_survey_fi s
JOIN typical t USING (crop, year)
LEFT JOIN clean.farm_area a USING (farm_id, crop, year)
LEFT JOIN clean.farm_delivery d USING (farm_id, crop, year);

INSERT INTO dq.issue (rule_id, source_table, record_key, issue_type, year, field, observed, applied, action, confidence, explanation, source_file, source_row)
SELECT 'SURVEY-N', 'farm_survey', record_key, 'decimal_shift', year, 'n_mineral_kg_ha', n_mineral_kg_ha::VARCHAR, n_mineral_clean::VARCHAR, 'corrected', 'medium',
       'Mineral N about 10x from the crop''s usual level', _source_file, _source_row
FROM clean.farm_survey WHERE is_n_shift
UNION ALL
SELECT 'SURVEY-YIELD', 'farm_survey', record_key, 'outlier_implausible', year, 'yield_t_ha', yield_t_ha::VARCHAR, yield_clean::VARCHAR, 'corrected', 'medium',
       'Reported yield over 3x what the farm delivered per hectare', _source_file, _source_row
FROM clean.farm_survey WHERE is_yield_outlier
UNION ALL
SELECT 'SURVEY-AREA', 'farm_survey', record_key, 'area_mismatch', year, 'area_ha', area_ha::VARCHAR, area_ha_parcels::VARCHAR, 'corrected', 'high',
       'Reported area differs from the parcel register; register used', _source_file, _source_row
FROM clean.farm_survey WHERE is_area_mismatch
UNION ALL
SELECT 'SURVEY-SOIL', 'farm_survey', record_key, 'soil_misreport', year, 'soil_type_reported', soil_type_reported, round(organic_share, 2)::VARCHAR, 'corrected', 'medium',
       'Reported mineral soil, but parcel data shows at least 30 % organic; parcel data used', _source_file, _source_row
FROM clean.farm_survey WHERE is_soil_misreport;

-- Farms that did not answer take the area-weighted mean of respondents for that crop
-- and year, with their own yield from deliveries. Harvest exceeds delivery by the
-- intake rejection rate, measured from respondents.
CREATE TABLE inv.farm_crop_year AS
WITH respondent_mean AS (
    SELECT crop, year,
           sum(n_mineral_clean * area_ha_parcels) / sum(area_ha_parcels) AS n_mineral,
           sum(coalesce(n_manure_kg_ha, 0) * area_ha_parcels) / sum(area_ha_parcels) AS n_manure,
           sum(coalesce(p_kg_ha, 0) * area_ha_parcels) / sum(area_ha_parcels) AS p,
           sum(coalesce(diesel_l_ha, 0) * area_ha_parcels) / sum(area_ha_parcels) AS diesel,
           sum(coalesce(lime_t_ha, 0) * area_ha_parcels) / sum(area_ha_parcels) AS lime,
           sum(coalesce(sprays, 0) * area_ha_parcels) / sum(area_ha_parcels) AS sprays,
           sum(low_carbon::INT * area_ha_parcels) / sum(area_ha_parcels) AS low_carbon_share,
           sum(coalesce(irrigated, false)::INT * area_ha_parcels) / sum(area_ha_parcels) AS irrigated_share,
           median(yield_clean / nullif(delivered_t_ha, 0)) AS harvest_per_delivered
    FROM clean.farm_survey WHERE area_ha_parcels IS NOT NULL GROUP BY 1, 2
),
inputs AS (
    SELECT d.farm_id, d.crop, d.year, d.delivered_kg, a.area_ha,
           a.organic_ha, a.organic_ha_map,
           s.survey_id IS NOT NULL AS has_survey,
           coalesce(s.n_mineral_clean, m.n_mineral) AS n_mineral,
           coalesce(s.n_manure_kg_ha, m.n_manure) AS n_manure,
           coalesce(s.p_kg_ha, m.p) AS p,
           coalesce(s.diesel_l_ha, m.diesel) AS diesel,
           coalesce(s.lime_t_ha, m.lime) AS lime,
           coalesce(s.sprays, m.sprays) AS sprays,
           coalesce(s.low_carbon::INT, m.low_carbon_share) AS low_carbon_share,
           coalesce(s.irrigated::INT, m.irrigated_share) AS irrigated_share,
           coalesce(s.yield_clean, d.delivered_kg / 1000 / a.area_ha * m.harvest_per_delivered) AS yield_t_ha,
           s._source_file, s._source_row
    FROM clean.farm_delivery d
    JOIN clean.farm_area a USING (farm_id, crop, year)
    JOIN respondent_mean m USING (crop, year)
    LEFT JOIN clean.farm_survey s USING (farm_id, crop, year)
),
per_ha AS (
    SELECT i.*, c.residue_n_per_t * yield_t_ha AS n_residue, k('n2o_n_to_n2o') * k('n2o_gwp') AS n2o_factor,
           g.location_t_per_mwh AS grid, c.kwh_per_t
    FROM inputs i
    JOIN ref.crop c USING (crop)
    JOIN ref.electricity_factor g ON g.country = 'FI' AND g.year = i.year
),
kg_ha AS (
    SELECT *,
           n_mineral * (low_carbon_share * k('fert_n_prod_lowcarbon') + (1 - low_carbon_share) * k('fert_n_prod'))
               + p * k('fert_p_prod') + p * 2.2 * k('fert_k_prod') AS fertiliser,
           (n_mineral * k('ef1_synthetic') + (n_manure + n_residue) * k('ef1_organic')) * n2o_factor AS n2o_direct,
           ((n_mineral * k('frac_gasf') + n_manure * k('frac_gasm')) * k('ef4_n2o_n')
               + (n_mineral + n_manure + n_residue) * k('frac_leach') * k('ef5_n2o_n')) * n2o_factor AS n2o_indirect,
           diesel * (k('diesel_ttw') + k('diesel_wtt')) AS diesel_kg,
           lime * k('lime') * 1000 AS lime_kg,
           sprays * k('spray_pass') AS pesticide,
           (kwh_per_t * yield_t_ha + 180 * irrigated_share) * grid AS electricity,
           k('org_soil_co2_t_ha') * 1000 + k('org_soil_n2o_n_kg_ha') * n2o_factor AS organic_soil_kg
    FROM per_ha
)
SELECT farm_id, crop, year, delivered_kg, area_ha, organic_ha, organic_ha_map, has_survey, yield_t_ha,
       area_ha * fertiliser / 1000 AS fertiliser_t,
       area_ha * n2o_direct / 1000 AS n2o_direct_t,
       area_ha * n2o_indirect / 1000 AS n2o_indirect_t,
       area_ha * diesel_kg / 1000 AS diesel_t,
       area_ha * lime_kg / 1000 AS lime_t,
       area_ha * pesticide / 1000 AS pesticide_t,
       area_ha * electricity / 1000 AS electricity_t,
       organic_ha * organic_soil_kg / 1000 AS organic_soil_t,
       fertiliser_t + n2o_direct_t + n2o_indirect_t + diesel_t + lime_t + pesticide_t + electricity_t + organic_soil_t AS total_t,
       _source_file, _source_row
FROM kg_ha;
