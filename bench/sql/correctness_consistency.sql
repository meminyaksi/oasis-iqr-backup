-- FPGA internal consistency: the outlier flag must be a clean function of the value, so every row
-- sharing a value must share a flag. This catches per-row bugs that a fence-reconstruction check
-- would miss (e.g. a value flagged in one row but not another -- not a contiguous threshold).
-- Result MUST be 0. @PATH@/@COL@ substituted by the runner.
SELECT count(*) AS values_with_inconsistent_flags
FROM (
  SELECT v
  FROM iqr_flags('@PATH@','@COL@') t(v,f)
  GROUP BY v
  HAVING count(DISTINCT f) > 1
);
