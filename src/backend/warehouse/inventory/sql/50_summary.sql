-- Same shape as tasks/templates/A2_inventory_2025_submission.csv.
CREATE VIEW inv.summary AS
WITH lines AS (
    SELECT year, scope,
           CASE WHEN category LIKE 'cat01%' THEN 'cat01_purchased_goods_services' ELSE category END AS category,
           sum(tco2e) AS tco2e
    FROM inv.contribution GROUP BY 1, 2, 3
)
SELECT year, scope, category, tco2e FROM lines
UNION ALL
SELECT year, 'total', scope || '_total', sum(tco2e) FROM lines
WHERE scope IN ('scope1', 'scope2_location', 'scope2_market', 'scope3') GROUP BY 1, 3;

-- Measurement only: compares the result with the public dev truths for 2023 and 2024.
CREATE VIEW inv.validation AS
WITH truth AS (
    SELECT * FROM tasks.a2_dev_inventory_2023 UNION ALL SELECT * FROM tasks.a2_dev_inventory_2024
)
SELECT t.year, t.scope, t.category, t.tco2e AS truth_tco2e, s.tco2e AS tco2e,
       (s.tco2e - t.tco2e) / t.tco2e * 100 AS error_pct
FROM truth t LEFT JOIN inv.summary s USING (year, scope, category);

-- Independent sanity check for years with no dev truth. The synthetic company follows
-- the published Scope 1 trajectory, so a large gap here points to a missed error.
CREATE VIEW inv.published_comparison AS
SELECT p.year, p.scope1 AS published_scope1, s.tco2e AS scope1,
       (s.tco2e - p.scope1) / p.scope1 * 100 AS error_pct
FROM raw.published_inventory_history p
JOIN inv.summary s ON s.year = p.year AND s.category = 'scope1_total';

CREATE VIEW inv.a2_submission AS
SELECT t.scope, t.category, round(s.tco2e, 2) AS tco2e,
       CASE WHEN t.category LIKE 'cat01%' THEN 'Valid supplier PCF, else default factor; spend-based services; contract farms per METHODOLOGY.md section 5, with organic soil from parcel data'
            WHEN t.category = 'cat02_capital_goods' THEN 'Capex spend x EEIO factor, reconciled to capex_projects'
            WHEN t.category = 'cat03_fuel_energy' THEN 'Fuel MWh x WTT; electricity and heat MWh x upstream factor'
            WHEN t.category = 'cat04_upstream_transport' THEN 'Inbound tkm x WTW factor; missing import legs estimated from peer lots'
            WHEN t.category = 'cat05_waste' THEN 'Tonnes x treatment factor; wastewater m3 x factor'
            WHEN t.category = 'cat06_business_travel' THEN 'De-duplicated pkm and hotel nights x factor'
            WHEN t.category = 'cat07_employee_commuting' THEN 'Cleaned 2025 survey mean x year-end headcount'
            WHEN t.category = 'cat09_downstream_transport' THEN 'Outbound tkm and frozen pallet-days x factor'
            WHEN t.category = 'cat11_use_of_sold_products' THEN 'Freezer and cooking kWh x grid factor of the market'
            WHEN t.category = 'cat12_end_of_life' THEN 'Packaging put on market x treatment mix'
            WHEN t.category = 'fugitive_refrigerants' THEN 'Top-up kg x AR6 GWP100 after unit and gas-code corrections'
            WHEN t.category = 'stationary_and_mobile_combustion' THEN 'Fuel MWh (NCV) x fossil factor; deliveries less stock change'
            WHEN t.scope = 'scope2_market' THEN 'MWh less registry GoOs of the same vintage x residual mix'
            WHEN t.scope = 'scope2_location' THEN 'MWh x national grid average'
            WHEN t.scope = 'memo' THEN 'Biogenic CO2 from fuels, outside Scope 1'
            ELSE 'Sum of lines' END AS method_note
FROM tasks.template_a2_inventory_2025_submission t
LEFT JOIN inv.summary s ON s.year = 2025 AND s.scope = t.scope AND s.category = t.category
ORDER BY t._source_row;
