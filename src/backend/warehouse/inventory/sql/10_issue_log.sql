-- One row per detected issue. clean.* tables hold the applied values; rows here
-- are derived from them, so the log can't disagree with what was applied.
-- record_key and issue_type follow docs/TASKS_AND_SCORING.md (task A1).
CREATE TABLE dq.issue (
    rule_id VARCHAR,
    source_table VARCHAR,
    record_key VARCHAR,
    issue_type VARCHAR,
    year INTEGER,
    field VARCHAR,
    observed VARCHAR,
    applied VARCHAR,
    action VARCHAR,       -- corrected / estimated / excluded / flagged
    confidence VARCHAR,   -- high: arithmetic or an authoritative source; medium: an estimate
    explanation VARCHAR,
    source_file VARCHAR,
    source_row BIGINT,
    review_status VARCHAR DEFAULT 'pending'  -- an expert approves before results are published
);
