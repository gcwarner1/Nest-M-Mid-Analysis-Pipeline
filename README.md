# NEST-M MID Analysis Pipeline

Scripts for taking raw DICOM data from the NEST-M study through BIDS conversion, fMRIPrep preprocessing, and Monetary Incentive Delay (MID) task GLM analysis.

For a full, step-by-step walkthrough written for a non-coding research coordinator, see the SOP document that accompanies this repo (`NEST-M_MID_Pipeline_SOP.docx`). This README is a technical quick-reference for the same pipeline.

## Pipeline overview

1. **Download raw data from Flywheel** (manual step, not scripted).
2. **Convert DICOMs to BIDS** — `Convert2Bids/run_all.sh`, which wraps DICOM→BIDS conversion, fieldmap insertion, BIDS validation, and merging into the master dataset.
3. **Preprocess with fMRIPrep** — `fmriPrep_preprocess.sh`, runs the `nipreps/fmriprep:25.2.5` Docker container.
4. **Run the MID task GLM analysis** — `mid_analysis.py`, first- and second-level GLMs, anterior insula (AIns) ROI extraction, and RT correlation (replicates MacNiven, Mortazavi & Knutson, 2024, *Biological Psychiatry*, Figures 4c/4d).

An optional, niche script (`compare_T1_T3.py`) compares AIns–RT relationships across two timepoints; it was built for a one-off conference analysis and needs manual editing (paths, hemisphere/ROI choice) before every use.

## Repository structure

```
scripts/
├── Convert2Bids/
│   ├── run_all.sh                 # one-command wrapper for the steps below
│   ├── convert_all.sh             # DICOM -> BIDS conversion (resumable, skips ambiguous sessions)
│   ├── add_fieldmaps.py           # adds spiral fieldmaps (no DICOM source)
│   ├── dcm2bids_config.json       # scanner series -> BIDS name mapping
│   ├── merge_into_nestm_bids.sh   # session-aware merge into the master BIDS dataset
│   └── README.md                  # technical notes specific to the conversion scripts
├── moveBadScans.py                # moves incomplete/restarted scans aside (see Known issues)
├── create_bids_jsons.py           # creates missing BOLD JSON sidecars
├── generateDatasetDescription.py  # generates dataset_description.json
├── fmriPrep_preprocess.sh         # runs fMRIPrep via Docker
├── mid_analysis.py                # MID task GLM analysis (first + second level)
└── compare_T1_T3.py               # optional/niche: T1 vs T3 AIns-RT comparison
```

## Requirements

- Python 3 with: `dcm2bids`, `numpy`, `nibabel`, `bids-validator-deno`, `nilearn`, `pandas`, `mne_bids`
- `dcm2niix` and `unzip` on your PATH
- Docker Desktop, for the `nipreps/fmriprep:25.2.5` image (must be running before you launch fMRIPrep — it does not start on its own after a computer restart)
- A FreeSurfer license file (referenced by `fmriPrep_preprocess.sh`)
- The Brainnetome atlas (`BN_Atlas_246_2mm.nii.gz`), for AIns ROI extraction in `mid_analysis.py`

## Quick start

```bash
# 1. Convert raw DICOMs to BIDS and merge into the master dataset
cd Convert2Bids
./run_all.sh <raw_root> <staging_out> [master_bids]

# 2. Preprocess with fMRIPrep (edit bids_root_dir and subj in the script first)
bash ../fmriPrep_preprocess.sh > fmriPrep.log 2>&1

# 3. Run the MID GLM analysis (edit SESS in the CONFIG section of mid_analysis.py first)
python ../mid_analysis.py [--no-skip-existing] [--n-jobs 1] [--session ses-T1]
```

## Script reference

| Script | Stage | Purpose |
|---|---|---|
| `Convert2Bids/run_all.sh` | Convert | One-command wrapper: unzip → convert → add fieldmaps → validate → (optional) merge |
| `Convert2Bids/convert_all.sh` | Convert | Auto-discovers every `H4M###[_T#]` session in the Flywheel export and runs the DICOM→BIDS conversion; resumable, skips already-converted and ambiguous/duplicate sessions rather than aborting |
| `Convert2Bids/add_fieldmaps.py` | Convert | Adds spiral fieldmaps (no DICOM source) into each session's `fmap/` |
| `Convert2Bids/merge_into_nestm_bids.sh` | Convert | Copies new subjects/sessions into the master dataset (never overwrites an existing session) and rebuilds `participants.tsv` |
| `Convert2Bids/dcm2bids_config.json` | Convert | Maps scanner series names to BIDS names |
| `moveBadScans.py` | Convert (cleanup) | Moves incomplete/restarted scans aside using a `redo` filename convention |
| `create_bids_jsons.py` | Convert (cleanup) | Creates minimal BOLD JSON sidecars (RepetitionTime + TaskName) for files missing one |
| `generateDatasetDescription.py` | Convert (cleanup) | Generates `dataset_description.json` for a BIDS dataset |
| `fmriPrep_preprocess.sh` | Preprocess | Runs fMRIPrep via Docker |
| `mid_analysis.py` | Analysis | First- and second-level MID GLM, AIns ROI extraction, RT correlation, figures |
| `compare_T1_T3.py` | Analysis (optional) | One-off comparison of AIns–RT relationships between two timepoints; requires manual editing before use |

## Known issues / gotchas

- **`moveBadScans.py`** has its input/output folder paths hardcoded with a leading `~`. Python does not expand `~` the way a shell does, so as written the script always exits immediately with "No outdir." Edit the two path variables to full absolute paths before running it.
- **`mid_analysis.py`**'s `--session` CLI flag only narrows a list that's already been filtered by the `SESS` constant near the top of the file — it cannot override it. Edit `SESS` directly for each run.
- **`compare_T1_T3.py`** has hardcoded paths from a specific past analysis; they will not match current output locations. Treat it as a template to copy and edit (paths, hemisphere/ROI) rather than a script to run as-is.
- Group-level statistics in `mid_analysis.py` are skipped for any contrast with fewer than 2 sessions.

## Documentation

The full Standard Operating Procedure — written for a new research coordinator with no coding background, covering every step from Flywheel download through final MID analysis output — accompanies this repository as `NEST-M_MID_Pipeline_SOP.docx`.
