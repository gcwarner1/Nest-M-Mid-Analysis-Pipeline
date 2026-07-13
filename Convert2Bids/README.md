# NEST-M: DICOM -> BIDS conversion

Converts a NEST-M Flywheel export into BIDS format, ready for fMRIPrep.
Auto-discovers every subject and session in the export -- no subject IDs are
hardcoded, so the same scripts work for every subject as they're collected,
including subjects who get scanned again at a later timepoint (up to 4
sessions/subject currently).

## How this differs from the NEST-A scripts

- **Raw layout is deeper.** The NEST-A raw export was a flat
  `<raw_root>/H7A007_T1/<session_label>/<series>/*.dicom.zip`. The NEST-M
  Flywheel export you downloaded mirrors the full Flywheel container
  hierarchy instead:
  `<raw_root>/SUBJECTS/<subject>/SESSIONS/<session_label>/ACQUISITIONS/<series>/FILES/*.dicom.zip`,
  with a `*.flywheel.json` metadata sidecar next to every folder/file.
  `convert_all.sh` now walks this structure directly. Point `<raw_root>` at
  either the folder that directly contains `SUBJECTS/`, or anywhere above it
  (e.g. the `nest-m` export folder) -- the script searches a few levels down
  for `SUBJECTS/` automatically.
- **Subject-folder naming is inconsistent** in the NEST-M export (`h4m001`,
  `H4M001_T2`, `h4m003_t4`, `H4M003` with no timepoint suffix at all, etc.).
  Matching is now case-insensitive against `H4M###[_T#]`, and a folder with
  no `_T#` suffix is treated as timepoint 1 (`ses-T1`). Everything gets
  normalized to canonical `sub-H4M###` / `ses-T#` regardless of how the raw
  folder was cased.
- **DTI/diffusion is now converted.** The NEST-M export includes a real DTI
  series (`DTI 2mm b1250 84dir(axial)`) with proper `.bval`/`.bvec` files,
  which NEST-A didn't have. `dcm2bids_config.json` has a `dwi` entry that
  converts it into `dwi/sub-*_ses-*_dwi.nii.gz` + `.bval` + `.bvec` + `.json`.
  This pipeline doesn't do anything further with it (no eddy-current/
  distortion correction) -- it's just there in BIDS form if/when you run a
  diffusion pipeline on it separately.
- **Merging is now session-aware, not just subject-aware.** Because NEST-M
  subjects come back for up to 4 timepoints spread over time, a subject
  already in the master dataset needs new sessions added to it later, not
  the whole subject skipped. `merge_into_nestm_bids.sh` now merges per
  `ses-*` folder: if the subject doesn't exist yet, the whole thing is
  copied; if it does exist, any timepoint it doesn't already have is added,
  and any timepoint that already exists is left untouched and flagged.
- **The conversion is resumable and never stops the whole run.**
  `convert_all.sh` checks the output (staging) folder before doing any work
  on a session, and skips it if it's already been converted -- so an
  interrupted or re-run batch doesn't waste time reprocessing everything.
  If a subject/timepoint's `SESSIONS/` folder contains more than one
  session subfolder (usually a duplicated or stray scan), that session is
  flagged as **AMBIGUOUS** and skipped -- both candidate folders' contents
  are printed so a human can tell at a glance which one is correct -- and
  the run keeps going with the rest of the batch rather than exiting. Any
  session skipped for this reason, for having no DICOMs, or (rarely) for
  being a case-variant duplicate pointing at the same subject/session, is
  collected into a "Failed to process" list printed at the very end of the
  run, so nothing silently falls through the cracks. In the batch you sent,
  this happens for real: `H4M018_T1` has two complete, duplicate-looking
  sessions (`33110` and `33193`), and `H4M016_T1` has one real numbered
  session plus a stray `unknown` session containing only an orphaned
  fieldmap. Fix the flagged raw folders (keep the correct session
  subfolder, remove/rename the stray one) and re-run the same command --
  already-converted sessions are skipped automatically, so only the fixed
  ones get (re)processed.
- **Everything else in the conversion (series -> BIDS mapping, fieldmap
  handling) is unchanged from NEST-A** -- the NEST-M scanner protocol uses
  the same series names (`T1w 1mm`, `T2w CUBE .8mm sag`, `conscious 2`,
  `nonconscious 2`, `Cue_Reactivity`, `MID_run1_BOLD`/`MID_run2_BOLD`,
  `spiral high-res fieldmap`).

## What you need installed (once)

```bash
pip install dcm2bids numpy nibabel bids-validator-deno
```

You also need `dcm2niix` (dcm2bids uses it) and `unzip` available on your
PATH -- both are standard. `dcm2niix` installs automatically with dcm2bids
on most systems; if not, install it separately.

## The one command

```bash
./run_all.sh <raw_root> <staging_out> [master_bids]
```

- `<raw_root>` -- the Flywheel export folder. Either the folder that
  directly contains `SUBJECTS/`, or anywhere above it.
- `<staging_out>` -- the folder where converted BIDS data is built. Can be
  reused across runs -- already-converted sessions are detected and
  skipped, so it's safe to point this at the same staging folder again
  after fixing a flagged subject or adding a new batch.
- `[master_bids]` -- OPTIONAL. Your existing master `NESTM_bids` dataset. If
  you provide it, newly-converted subjects/sessions are merged in at the
  end. Leave it off to just build + validate the new data and stop.

### Typical use: convert a new batch and add it to the master dataset

```bash
./run_all.sh \
  "~/pegasus/flywheel/nest-m" \
  "~/pegasus/NESTM_staging" \
  "~/pegasus/NESTM_bids"
```

That runs all four steps in order:
1. Unzip DICOMs + convert every not-yet-converted session with dcm2bids
   (skipping sessions already present in staging, and skipping/flagging
   ambiguous ones without stopping the run)
2. Add the spiral fieldmaps (these have no DICOM, so they're handled separately)
3. Validate the new staging dataset
4. Merge new subjects/sessions into the master dataset and re-validate

### Just convert, don't merge yet

```bash
./run_all.sh \
  "~/pegasus/flywheel/nest-m" \
  "~/pegasus/NESTM_staging"
```

## What counts as a valid subject/timepoint folder

Folders matching `H4M###` optionally followed by `_T#` (case-insensitive,
e.g. `H4M014_T2`, `h4m014_t2`, or plain `H4M014` for timepoint 1) are
processed. Anything else -- typos, test/phantom folders (`chaztest`,
`phantom`, `phantom2`, `sam`, `samtest`, `test`, `test_eb`, `test_rc` all
showed up in your export), or a stray suffix like `H4M001redo` -- is skipped
with a warning printed to the screen. A "redo" folder in particular usually
means a partial rescan of one timepoint; it's deliberately NOT auto-merged
into the original session, since deciding which runs should replace which is
a judgment call. Check the printed `SKIPPING` lines and resolve any real data
by hand (rename the folder to match the pattern) before re-running.

## Ambiguous sessions and resuming (no more full-run stops)

If a subject's timepoint folder contains **more than one** session subfolder
under `SESSIONS/` (e.g. two Flywheel session IDs nested under one
`H4M018_T1`), `convert_all.sh` prints both subfolders' acquisition lists so
you can tell at a glance which one looks complete/correct -- then **flags
that session as AMBIGUOUS, skips it, and moves on** to the rest of the
batch. It does not stop the run. This is almost always a data-entry/export
mistake, or in the `H4M016_T1` case, a fieldmap that got uploaded into the
wrong (orphaned) session container.

Every session skipped this way -- along with any skipped for having no
DICOMs found, or for being a same-run case-variant duplicate -- is
collected into a **"Failed to process: ..."** summary printed at the very
end of the run, so you have one place to look for everything that still
needs a human decision. Non-matching folders (typos, test/phantom, `redo`
suffixes) are intentionally *not* included in this list -- those are
expected, routine skips, not problems.

To fix a flagged session: go to the raw folder, keep the correct session
subfolder, remove or rename the stray one, then simply re-run the exact
same `run_all.sh` / `convert_all.sh` command with the same staging folder.
The script checks the staging output first and skips anything already
converted, so only the sessions you just fixed (plus anything new) get
processed -- you never need to wipe the staging folder and start over.

## After conversion: fMRIPrep

Once the master dataset validates, preprocess with your fMRIPrep wrapper
script (adapt `fmriPrep_preprocess.sh` from NEST-A: same Docker invocation,
work-directory bind-mount, and "skip subjects with complete derivatives
already" behavior apply here too). One thing to double check when adapting
it: NEST-A used `--bold2anat-init t1w` because it had no consistent T2w --
NEST-M's raw data actually does have a `T2w CUBE .8mm sag` series for most
sessions (now converted by this pipeline), so it's worth checking whether
`--bold2anat-init t2w` or fMRIPrep's default behavior is more appropriate
here once T2w coverage across the dataset is more complete.

## Files in this folder

| File | What it does |
|---|---|
| `run_all.sh` | one-command wrapper: runs the four steps below in order |
| `convert_all.sh` | walks the SUBJECTS/SESSIONS/ACQUISITIONS/FILES export, unzips DICOMs, and runs dcm2bids for every discovered session not already converted; skips (and lists) ambiguous/duplicate/DICOM-less sessions instead of stopping |
| `dcm2bids_config.json` | maps each scanner series name to its BIDS name |
| `add_fieldmaps.py` | adds the spiral fieldmaps (no DICOM source) to `fmap/`, using the raw-path map `convert_all.sh` records |
| `merge_into_nestm_bids.sh` | copies new subjects/sessions into the master dataset (session-aware), rebuilds `participants.tsv` |
| `fmriPrep_preprocess.sh` | (carry over / adapt from NEST-A) runs fMRIPrep on the BIDS data via Docker |

## What gets converted (series -> BIDS)

| Scanner series | BIDS output |
|---|---|
| `conscious 2` | `task-con_bold` (numbered run-1/2/... if repeated) |
| `nonconscious 2` | `task-noncon_bold` (numbered run-1/2/... if repeated) |
| `Cue_Reactivity` | `task-cue_bold` (numbered run-1/2/... if repeated) |
| `MID_run1_BOLD` / `MID_run2_BOLD` | `task-mid_run-1/2_bold` |
| `T1w 1mm` | `T1w` |
| `T2w CUBE .8mm sag` | `T2w` |
| `DTI 2mm b1250 84dir(axial)` | `dwi` (+ `.bval`/`.bvec`) |
| `spiral high-res fieldmap` | `fmap/` magnitude + fieldmap (Units: Hz) |

Intentionally excluded: `Localizer`, `GE HOS FOV28*` calibration scans. These
are skipped automatically at the unzip stage (to save time/disk) as well as
by `dcm2bids_config.json` -- no action needed. Physio recordings
(`*_physio.gephysio.zip`) and Flywheel QA files (`*.qa.json`/`*.qa.png`) are
also ignored -- they're not part of the BIDS conversion.

## Known data issues in the batch you sent (worth resolving by hand)

- `H4M018_T1` -- two complete session subfolders (`33110`, `33193`).
  Flagged as AMBIGUOUS and skipped; will appear in the "Failed to process"
  list until one is removed/renamed and the run is repeated.
- `H4M016_T1` -- a real numbered session (`33039`) plus a stray `unknown`
  session containing only an orphaned fieldmap acquisition. Also flagged
  as AMBIGUOUS and skipped for the same reason.
- `H4M001redo` -- a partial rescan (Localizer, GE HOS, MID runs, T1w; no
  T2w, no con/noncon/cue, and its fieldmap is missing the actual fieldmap
  file, just a raw pfile) sitting outside the normal `H4M001`/`H4M001_T#`
  naming. Skipped automatically (not added to the "Failed to process"
  list, since this is a routine naming skip, not a data problem); decide
  by hand whether/how it should replace anything in the existing `H4M001`
  timepoint.
- Test/phantom folders (`chaztest`, `phantom`, `phantom2`, `sam`, `samtest`,
  `test`, `test_eb`, `test_rc`) are skipped automatically, as expected.
