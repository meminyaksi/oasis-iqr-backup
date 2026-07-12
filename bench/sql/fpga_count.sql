-- FPGA timed query: end result = number of IQR outliers, computed by the FPGA (decode + IQR) via
-- the iqr_flags table function. @PATH@/@COL@ substituted by runner. Needs the card + huge pages.
SELECT count(*) FILTER (WHERE f) FROM iqr_flags('@PATH@','@COL@') t(v,f);
