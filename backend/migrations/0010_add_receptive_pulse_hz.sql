-- The rate matched on the app's metronome, in hertz.
--
-- The column is the stored fact rather than the minute figure the gauge produces: fifteen of the
-- gauge's values are not whole hertz, so the client writes `rate / 60` at full precision and derives
-- the minute reading back for the control. NULL means no reading was given — `0` would be a claim
-- that none was felt, which is a different statement.
ALTER TABLE receptive_inactivities ADD COLUMN pulse_hz REAL;
