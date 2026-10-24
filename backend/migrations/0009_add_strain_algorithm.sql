-- Gives every strain row the formula that produced it, and puts the formulas in this database.
--
-- The app's `strains` table has carried a score and no record of how it was computed, so a row
-- written before its motion term existed and one written after were indistinguishable. `v35` on the
-- phone added a name to the row and a `strainAlgorithms` reference table that defines each name; this
-- migration is the same change on the server, so the file carrying the data also carries the
-- explanation of what the data means.
--
-- **The client decides the version and this Worker stores it.** The formula is computed on the
-- phone, so the phone is the only thing that can say which one ran. A row from a client older than
-- the field arrives with `null`, which is stored as `null` rather than guessed at.
--
-- **`algorithm` is nullable and undefaulted**, matching `source` one column up: `null` is the honest
-- value for a row written before the column existed and for a client that does not send it. An empty
-- string is refused by the API's schema rather than by a CHECK, because this column's vocabulary is
-- open — a new version is a new string, and a constraint here would have to be migrated again.

ALTER TABLE strains ADD COLUMN algorithm TEXT;

-- The reference catalogue. Nothing joins it; it is read by an operator holding the database open and
-- by the API's own documentation. The rows are **literal and frozen**: a later version appends a row,
-- never edits one, because an edit would rewrite what historical rows claim they were computed by.
--
-- `parameters` is a JSON document rather than a column per constant, because every version defines a
-- different set of constants and a nullable-column-per-parameter table would be mostly NULL and
-- could not say what it meant.
CREATE TABLE strain_algorithms (
    version     TEXT NOT NULL PRIMARY KEY,
    formula     TEXT NOT NULL,
    parameters  TEXT NOT NULL,
    notes       TEXT,
    created_at  TEXT NOT NULL
);

INSERT INTO strain_algorithms (version, formula, parameters, notes, created_at) VALUES (
    'whoop-export',
    'WHOOP''s own Day Strain, read from the bundled export and stored verbatim.',
    '{}',
    'Not this app''s computation. The export carries no R-R series, so feeding it to the integrator would produce a different quantity wearing the same name.',
    '2026-01-01T00:00:00Z'
);

INSERT INTO strain_algorithms (version, formula, parameters, notes, created_at) VALUES (
    'hr-zone-v1',
    'L = sum over samples of weight(bpm) x duration; score = 21 * (1 - exp(-k_day * L)), where weight is the five-zone table for a rate in a band, 1 for a rate above resting but below zone 1, and 0 at or below resting.',
    '{"zoneWeights":{"1":1,"2":2,"3":4.5,"4":9,"5":16},"zoneReserveFractions":[[0.5,0.6],[0.6,0.7],[0.7,0.8],[0.8,0.9],[0.9,1.0]],"lowIntensityBandWeight":1,"dayStrainScalingFactor":0.00001085,"firstSampleDurationSeconds":1,"maximumSampleGapSeconds":5}',
    'The heart-rate integral, with five Karvonen reserve bands and the weight-1 low-intensity band. Everything the app computed before hr-motion-v2.',
    '2026-01-01T00:00:00Z'
);

INSERT INTO strain_algorithms (version, formula, parameters, notes, created_at) VALUES (
    'hr-motion-v2',
    'For each 30-second window: max(hrLoad, motionLoad), where hrLoad is v1''s weighted seconds and motionLoad = motionWeight(ENMO) x min(30, samples/100); dayLoad = the sum over windows with an epoch of that maximum and over windows without one of hrLoad alone; score = 21 * (1 - exp(-k_day * dayLoad)). A day with no HR samples scores nothing.',
    '{"zoneWeights":{"1":1,"2":2,"3":4.5,"4":9,"5":16},"zoneReserveFractions":[[0.5,0.6],[0.6,0.7],[0.7,0.8],[0.8,0.9],[0.9,1.0]],"lowIntensityBandWeight":1,"dayStrainScalingFactor":0.00001085,"firstSampleDurationSeconds":1,"maximumSampleGapSeconds":5,"motionCombination":"per-30s-window-max","motionEpochSeconds":30,"motionReferenceGravityG":1,"motionSamplesPerSecond":100,"motionWeightTable":[{"enmoBelowG":0.02,"weight":0},{"enmoBelowG":0.05,"weight":1},{"enmoBelowG":0.1,"weight":2},{"enmoBelowG":0.2,"weight":3},{"enmoBelowG":null,"weight":4}]}',
    'Adds the wrist-motion term so work that does not raise the heart rate counts. The weight table is the app''s calibration, not WHOOP''s: a hard 8-hour manual day is about +3 ring points over a quiet one.',
    '2026-10-23T00:00:00Z'
);
