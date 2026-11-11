-- One row per source record and emission line. Everything reported is a sum of this.
CREATE TABLE inv.contribution (
    year INTEGER, scope VARCHAR, category VARCHAR, line_item VARCHAR,
    record_key VARCHAR, activity DOUBLE, activity_unit VARCHAR,
    factor DOUBLE, factor_unit VARCHAR, factor_ref VARCHAR,
    tco2e DOUBLE, source_file VARCHAR, source_row BIGINT
);

-- All fuel use, in MWh: meters, plus deliveries less stock change (METHODOLOGY.md section 2).
CREATE VIEW inv.fuel_use AS
SELECT year, site_id, carrier, record_key, mwh, _source_file, _source_row
FROM clean.energy_meter WHERE carrier NOT IN ('electricity', 'steam', 'district_heat')
UNION ALL
SELECT d.year, d.site_id, d.carrier, d.record_key, d.quantity_clean * n.mwh_per_unit, d._source_file, d._source_row
FROM clean.fuel_delivery d JOIN ref.ncv n USING (carrier)
UNION ALL
SELECT s.year, s.site_id, s.carrier, 'fuel_stock:' || s.site_id || ':' || s.carrier || ':' || s.year,
       -s.stock_change * n.mwh_per_unit, s._source_file, s._source_row
FROM raw.fuel_stock_changes s JOIN ref.ncv n USING (carrier);

CREATE VIEW inv.electricity AS
SELECT e.*, s.country FROM clean.energy_meter e JOIN raw.sites s USING (site_id) WHERE e.carrier = 'electricity';

CREATE VIEW inv.heat AS
SELECT * FROM clean.energy_meter WHERE carrier IN ('steam', 'district_heat');

INSERT INTO inv.contribution
-- Scope 1
SELECT year, 'scope1', 'stationary_and_mobile_combustion', site_id || ':' || carrier, record_key,
       mwh, 'MWh', fossil_t_per_mwh, 't/MWh', 'ref.fuel:' || carrier, mwh * fossil_t_per_mwh, _source_file, _source_row
FROM inv.fuel_use JOIN ref.fuel USING (carrier)
UNION ALL
SELECT r.year, 'scope1', 'fugitive_refrigerants', r.site_id || ':' || r.refrigerant_clean, r.record_key,
       r.kg_clean, 'kg', g.gwp / 1000, 't/kg', 'ref.refrigerant_gwp:' || r.refrigerant_clean, r.kg_clean * g.gwp / 1000, r._source_file, r._source_row
FROM clean.refrigerant r JOIN ref.refrigerant_gwp g ON g.refrigerant = r.refrigerant_clean
UNION ALL
-- Memo: biogenic CO2 is reported beside Scope 1, not in it.
SELECT year, 'memo', 'biogenic_co2_scope1', site_id || ':' || carrier, record_key,
       mwh, 'MWh', biogenic_t_per_mwh, 't/MWh', 'ref.fuel:' || carrier, mwh * biogenic_t_per_mwh, _source_file, _source_row
FROM inv.fuel_use JOIN ref.fuel USING (carrier) WHERE biogenic_t_per_mwh > 0
UNION ALL
-- Scope 2
SELECT e.year, 'scope2_location', 'purchased_electricity', e.site_id, e.record_key,
       e.mwh, 'MWh', f.location_t_per_mwh, 't/MWh', 'ref.electricity_factor:' || e.country, e.mwh * f.location_t_per_mwh, e._source_file, e._source_row
FROM inv.electricity e JOIN ref.electricity_factor f USING (country, year)
UNION ALL
SELECT e.year, 'scope2_market', 'purchased_electricity', e.site_id, e.record_key,
       e.mwh, 'MWh', f.residual_t_per_mwh, 't/MWh', 'ref.electricity_factor:' || e.country, e.mwh * f.residual_t_per_mwh, e._source_file, e._source_row
FROM inv.electricity e JOIN ref.electricity_factor f USING (country, year)
UNION ALL
-- Each certificate takes its MWh off at the residual mix, capped at the site's consumption.
SELECT g.consumption_year, 'scope2_market', 'purchased_electricity', g.beneficiary_site, 'goo:' || g.cancellation_id,
       -g.mwh * cap.share, 'MWh', f.residual_t_per_mwh, 't/MWh', 'ref.electricity_factor:' || s.country,
       -g.mwh * cap.share * f.residual_t_per_mwh, g._source_file, g._source_row
FROM clean.goo g
JOIN raw.sites s ON s.site_id = g.beneficiary_site
JOIN ref.electricity_factor f ON f.country = s.country AND f.year = g.consumption_year
JOIN (
    SELECT c.site_id, c.year, least(1, u.mwh / c.mwh) AS share
    FROM (SELECT beneficiary_site AS site_id, consumption_year AS year, sum(mwh) AS mwh FROM clean.goo WHERE is_valid GROUP BY 1, 2) c
    JOIN (SELECT site_id, year, sum(mwh) AS mwh FROM inv.electricity GROUP BY 1, 2) u USING (site_id, year)
) cap ON cap.site_id = g.beneficiary_site AND cap.year = g.consumption_year
WHERE g.is_valid
UNION ALL
SELECT h.year, 'scope2_location', 'purchased_heat_steam', h.site_id, h.record_key,
       h.mwh, 'MWh', f.t_per_mwh, 't/MWh', 'ref.heat_location_factor', h.mwh * f.t_per_mwh, h._source_file, h._source_row
FROM inv.heat h JOIN ref.heat_location_factor f USING (year)
UNION ALL
SELECT h.year, 'scope2_market', 'purchased_heat_steam', h.site_id, h.record_key,
       h.mwh, 'MWh', coalesce(s.t_per_mwh, 0), 't/MWh', 'heat_supplier_factors:' || h.site_id, h.mwh * coalesce(s.t_per_mwh, 0), h._source_file, h._source_row
FROM inv.heat h LEFT JOIN raw.heat_supplier_factors s USING (site_id, year)
UNION ALL
-- Category 1: purchased goods. Supplier PCF if valid, otherwise the material's default factor.
SELECT e.year, 'scope3', 'cat01_purchased_goods', e.material_id_clean || ':' || e.supplier_id, e.record_key,
       e.qty_kg, 'kg', coalesce(p.pcf_excluding_biogenic, f.kgco2e_per_unit), 'kgCO2e/kg',
       coalesce(p.record_key, m.default_ef_id),
       e.qty_kg * coalesce(p.pcf_excluding_biogenic, f.kgco2e_per_unit) / 1000, e._source_file, e._source_row
FROM clean.erp e
JOIN raw.materials m ON m.material_id = e.material_id_clean
JOIN raw.emission_factor_library f ON f.ef_id = m.default_ef_id
LEFT JOIN clean.pcf p ON p.supplier_id = e.supplier_id AND p.material_id = e.material_id_clean AND p.year = e.year AND p.is_valid
WHERE NOT e.is_duplicate AND m.material_group NOT IN ('service', 'capex')
UNION ALL
SELECT year, 'scope3', 'cat01_purchased_goods', 'contract_farming:FI_SW:' || crop, 'farm:' || farm_id || ':' || crop || ':' || year,
       delivered_kg, 'kg', total_t * 1000 / delivered_kg, 'kgCO2e/kg', 'inv.farm_crop_year', total_t, _source_file, _source_row
FROM inv.farm_crop_year
UNION ALL
-- Categories 1 (services) and 2: spend-based
SELECT e.year, 'scope3', CASE m.material_group WHEN 'service' THEN 'cat01_purchased_services' ELSE 'cat02_capital_goods' END,
       e.material_id_clean, e.record_key, e.amount_eur, 'EUR', f.kgco2e_per_unit, 'kgCO2e/EUR', m.default_ef_id,
       e.amount_eur * f.kgco2e_per_unit / 1000, e._source_file, e._source_row
FROM clean.erp e
JOIN raw.materials m ON m.material_id = e.material_id_clean
JOIN raw.emission_factor_library f ON f.ef_id = m.default_ef_id
WHERE NOT e.is_duplicate AND m.material_group IN ('service', 'capex')
UNION ALL
-- Category 3
SELECT year, 'scope3', 'cat03_fuel_energy', 'wtt:' || carrier, record_key, mwh, 'MWh', ef(wtt_ef_id), 'kgCO2e/MWh', wtt_ef_id,
       mwh * ef(wtt_ef_id) / 1000, _source_file, _source_row
FROM inv.fuel_use JOIN ref.fuel USING (carrier)
UNION ALL
SELECT year, 'scope3', 'cat03_fuel_energy', 'elec_upstream:' || site_id, record_key, mwh, 'MWh',
       ef('EF-ELEC-UPSTREAM-' || country), 'kgCO2e/MWh', 'EF-ELEC-UPSTREAM-' || country,
       mwh * ef('EF-ELEC-UPSTREAM-' || country) / 1000, _source_file, _source_row
FROM inv.electricity
UNION ALL
SELECT year, 'scope3', 'cat03_fuel_energy', 'heat_upstream', record_key, mwh, 'MWh', ef('EF-HEAT-UPSTREAM'), 'kgCO2e/MWh', 'EF-HEAT-UPSTREAM',
       mwh * ef('EF-HEAT-UPSTREAM') / 1000, _source_file, _source_row
FROM inv.heat
UNION ALL
-- Categories 4 and 9: transport
SELECT year, 'scope3', CASE direction WHEN 'inbound' THEN 'cat04_upstream_transport' ELSE 'cat09_downstream_transport' END,
       direction || ':' || ef_id, record_key, tkm, 'tkm', ef(ef_id), 'kgCO2e/tkm', ef_id, tkm * ef(ef_id) / 1000, _source_file, _source_row
FROM clean.shipment
UNION ALL
SELECT year, 'scope3', 'cat09_downstream_transport', 'frozen_warehousing', 'warehousing:' || year, pallet_days, 'pallet_days',
       ef('EF-PALLETDAY-FROZEN'), 'kgCO2e/pallet_day', 'EF-PALLETDAY-FROZEN', pallet_days * ef('EF-PALLETDAY-FROZEN') / 1000, _source_file, _source_row
FROM raw.frozen_warehousing
UNION ALL
-- Category 5
SELECT year, 'scope3', 'cat05_waste', site_id || ':' || waste_stream, record_key, t, 't', ef(ef_id), 'kgCO2e/t', ef_id,
       t * ef(ef_id) / 1000, _source_file, _source_row
FROM clean.waste
UNION ALL
SELECT year, 'scope3', 'cat05_waste', 'wastewater_third_party', 'wastewater:' || site_id || ':' || year, m3, 'm3', ef('EF-WASTEWATER-MUNI'), 'kgCO2e/m3', 'EF-WASTEWATER-MUNI',
       m3 * ef('EF-WASTEWATER-MUNI') / 1000, _source_file, _source_row
FROM raw.wastewater_third_party
UNION ALL
-- Category 6
SELECT year, 'scope3', 'cat06_business_travel', CASE mode WHEN 'flight' THEN 'flights' ELSE 'rail' END, record_key, pkm, 'pkm',
       ef(CASE mode WHEN 'flight' THEN 'EF-PKM-FLIGHT-SHORT' ELSE 'EF-PKM-TRAIN' END), 'kgCO2e/pkm',
       CASE mode WHEN 'flight' THEN 'EF-PKM-FLIGHT-SHORT' ELSE 'EF-PKM-TRAIN' END,
       pkm * ef(CASE mode WHEN 'flight' THEN 'EF-PKM-FLIGHT-SHORT' ELSE 'EF-PKM-TRAIN' END) / 1000, _source_file, _source_row
FROM clean.travel WHERE NOT is_duplicate
UNION ALL
SELECT year, 'scope3', 'cat06_business_travel', 'hotels', record_key, nights, 'nights', ef('EF-HOTEL-NIGHT'), 'kgCO2e/night', 'EF-HOTEL-NIGHT',
       nights * ef('EF-HOTEL-NIGHT') / 1000, _source_file, _source_row
FROM clean.travel WHERE NOT is_duplicate AND nights > 0
UNION ALL
-- Category 7: each 2025 response stands for headcount / respondents at its site, in every year.
SELECT h.year, 'scope3', 'cat07_employee_commuting', c.site_id, c.record_key,
       c.annual_pkm * h.headcount / c.responses, 'pkm', c.kg_per_pkm, 'kgCO2e/pkm', c.factor_ref,
       c.annual_pkm * c.kg_per_pkm * h.headcount / c.responses / 1000, c._source_file, c._source_row
FROM (
    SELECT *, one_way_km_clean * 2 * days_on_site_per_week * 46 AS annual_pkm,
           count(*) OVER (PARTITION BY site_id) AS responses,
           CASE mode_clean WHEN 'car' THEN ef('EF-PKM-CAR') WHEN 'carpool' THEN ef('EF-PKM-CAR') / 2
                           WHEN 'bus' THEN ef('EF-PKM-BUS') WHEN 'train' THEN ef('EF-PKM-TRAIN')
                           WHEN 'bike_walk' THEN 0 WHEN 'ev_car' THEN 0.03 END AS kg_per_pkm,
           'commute_mode:' || mode_clean AS factor_ref
    FROM clean.commuting
) c JOIN raw.headcount h USING (site_id)
UNION ALL
-- Categories 11 and 12
SELECT s.year, 'scope3', 'cat11_use_of_sold_products', s.product_group || ':' || s.market,
       'sales:' || s.year || '-' || s.month || ':' || s.product_group || ':' || s.site_id || ':' || s.market,
       s.t_sold * 1000 * p.use_kwh_per_kg, 'kWh', g.t_per_mwh, 't/MWh', 'ref.market_grid:' || s.market,
       s.t_sold * 1000 * p.use_kwh_per_kg * g.t_per_mwh / 1000, s._source_file, s._source_row
FROM raw.sales_volumes s
JOIN ref.product_group p USING (product_group)
JOIN ref.market_grid g ON g.market = s.market AND g.year = s.year
WHERE p.use_kwh_per_kg > 0
UNION ALL
SELECT s.year, 'scope3', 'cat12_end_of_life', s.product_group || ':' || s.market,
       'sales:' || s.year || '-' || s.month || ':' || s.product_group || ':' || s.site_id || ':' || s.market,
       s.t_sold, 't', (p.plastic_kg_per_t * k('eol_plastic_t_per_t') + p.board_kg_per_t * k('eol_board_t_per_t')) / 1000, 'tCO2e/t', 'ref.product_group:' || s.product_group,
       s.t_sold * (p.plastic_kg_per_t * k('eol_plastic_t_per_t') + p.board_kg_per_t * k('eol_board_t_per_t')) / 1000, s._source_file, s._source_row
FROM raw.sales_volumes s JOIN ref.product_group p USING (product_group);

-- The canonical inventory covers 2021-2025; other years in the feeds are context only.
DELETE FROM inv.contribution WHERE year NOT BETWEEN 2021 AND 2025;
