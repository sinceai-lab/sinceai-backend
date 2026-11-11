-- ERP purchase lines. Order matters: duplicates and material codes are settled
-- first, because price medians are computed per corrected material.
CREATE TABLE clean.erp AS
WITH base AS (
    SELECT e.*, year(posting_date) AS year,
           'erp:' || doc_no || ':' || line_no AS record_key,
           net_amount / fx.per_eur AS amount_eur_raw,
           CASE uom WHEN 'TO' THEN quantity * 1000 WHEN 'KG' THEN quantity ELSE 0 END AS qty_kg_raw,
           -- The line text is typed from the document; the code is what gets mis-keyed.
           coalesce(t.material_id, e.material_id) AS material_id_clean,
           -- Same supplier, material, quantity and amount as an earlier line. Matched on
           -- content because the 51... number range also holds legitimate capex lines.
           movement_type = 101 AND row_number() OVER (
               PARTITION BY movement_type, supplier_id, e.material_id, quantity, net_amount, e.currency
               ORDER BY doc_no, line_no) > 1 AS is_duplicate
    FROM raw.erp_purchase_lines_2021_2025 e
    JOIN ref.fx ON fx.currency = e.currency
    LEFT JOIN raw.materials t ON t.erp_name = e.material_text
),
priced AS (
    SELECT *,
           amount_eur_raw / nullif(qty_kg_raw, 0) AS unit_price,
           median(amount_eur_raw / nullif(qty_kg_raw, 0))
               FILTER (WHERE movement_type = 101 AND NOT is_duplicate AND uom <> 'EUR')
               OVER (PARTITION BY material_id_clean, year) AS median_price,
           median(amount_eur_raw) FILTER (WHERE uom = 'EUR' AND NOT is_duplicate)
               OVER (PARTITION BY material_id_clean, year) AS median_spend
    FROM base
),
usual_currency AS (
    SELECT supplier_id, mode(currency) AS currency FROM base WHERE uom <> 'EUR' GROUP BY 1
),
capex_control AS (
    -- capex_projects is an independent total. An excess in ERP that matches one line
    -- being SEK typed as EUR identifies that line, even though large capex is normal.
    SELECT p.year, e.record_key
    FROM (SELECT year, sum(capex_eur) AS total FROM raw.capex_projects GROUP BY 1) p
    JOIN (SELECT year, sum(amount_eur_raw) AS total FROM priced
          WHERE material_id_clean IN ('M950', 'M951') AND NOT is_duplicate GROUP BY 1) b USING (year)
    JOIN priced e ON e.year = p.year AND e.material_id_clean IN ('M950', 'M951') AND NOT e.is_duplicate
    WHERE abs(e.amount_eur_raw * (1 - 1 / (SELECT per_eur FROM ref.fx WHERE currency = 'SEK'))
              - (b.total - p.total)) < 0.001 * p.total
      AND b.total - p.total > 0.01 * p.total
),
flagged AS (
    SELECT p.*,
           movement_type = 101 AND uom = 'KG' AND unit_price / median_price > 300 AS is_unit_error,
           -- A price about 10x high is either a quantity one decimal low, or a foreign amount
           -- posted as EUR. The supplier's usual currency tells them apart.
           movement_type = 101 AND uom <> 'EUR' AND p.currency = 'EUR' AND u.currency <> 'EUR' AS is_goods_currency_error,
           movement_type = 101 AND uom IN ('KG', 'TO') AND NOT is_goods_currency_error
               AND (unit_price / median_price BETWEEN 0.05 AND 0.16 OR unit_price / median_price BETWEEN 6 AND 20) AS is_decimal_shift,
           (uom = 'EUR' AND material_id_clean NOT IN ('M950', 'M951') AND amount_eur_raw / median_spend BETWEEN 5 AND 20)
               OR c.record_key IS NOT NULL AS is_spend_currency_error
    FROM priced p
    LEFT JOIN capex_control c USING (record_key)
    LEFT JOIN usual_currency u USING (supplier_id)
)
SELECT *,
       qty_kg_raw * CASE WHEN is_unit_error THEN 1000
                         WHEN is_decimal_shift AND unit_price > median_price THEN 10
                         WHEN is_decimal_shift THEN 0.1 ELSE 1 END AS qty_kg,
       amount_eur_raw / CASE WHEN is_spend_currency_error
                             THEN (SELECT per_eur FROM ref.fx WHERE currency = 'SEK') ELSE 1 END AS amount_eur
FROM flagged;

INSERT INTO dq.issue (rule_id, source_table, record_key, issue_type, year, field, observed, applied, action, confidence, explanation, source_file, source_row)
SELECT 'ERP-DUP', 'erp_purchase_lines', record_key, 'duplicate_record', year, '*', doc_no, NULL, 'excluded', 'high',
       'Same supplier, material, quantity and amount as an earlier line', _source_file, _source_row
FROM clean.erp WHERE is_duplicate
UNION ALL
SELECT 'ERP-MATERIAL', 'erp_purchase_lines', record_key, 'material_mismatch', year, 'material_id', material_id, material_id_clean, 'corrected', 'high',
       'Line text "' || material_text || '" belongs to a different material code', _source_file, _source_row
FROM clean.erp WHERE material_id <> material_id_clean AND NOT is_duplicate
UNION ALL
SELECT 'ERP-UNIT', 'erp_purchase_lines', record_key, 'unit_error', year, 'quantity', quantity::VARCHAR, qty_kg::VARCHAR, 'corrected', 'high',
       'Unit price ' || round(unit_price / median_price) || 'x the material median: tonnes keyed with uom KG', _source_file, _source_row
FROM clean.erp WHERE is_unit_error AND NOT is_duplicate
UNION ALL
SELECT 'ERP-DECIMAL', 'erp_purchase_lines', record_key, 'decimal_shift', year, 'quantity', quantity::VARCHAR, qty_kg::VARCHAR, 'corrected', 'high',
       'Unit price ' || round(unit_price / median_price, 2) || 'x the material median: quantity shifted one decimal', _source_file, _source_row
FROM clean.erp WHERE is_decimal_shift AND NOT is_duplicate
UNION ALL
SELECT 'ERP-GOODS-FX', 'erp_purchase_lines', record_key, 'currency_error', year, 'currency', currency, NULL, 'flagged', 'medium',
       'Posted in EUR but this supplier invoices in another currency. Quantity is unaffected, so no emissions impact', _source_file, _source_row
FROM clean.erp WHERE is_goods_currency_error AND NOT is_duplicate
UNION ALL
SELECT 'ERP-SPEND-FX', 'erp_purchase_lines', record_key, 'currency_error', year, 'net_amount', net_amount::VARCHAR, amount_eur::VARCHAR, 'corrected', 'high',
       'Spend matches a SEK amount posted as EUR', _source_file, _source_row
FROM clean.erp WHERE is_spend_currency_error AND NOT is_duplicate;
