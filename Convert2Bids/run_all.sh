#!/usr/bin/env bash
# run_all.sh -- one-command NEST-M DICOM -> BIDS pipeline
#
# Runs the whole conversion end to end:
#   1. convert_all.sh    unzip DICOMs + dcm2bids for every discovered session
#   2. add_fieldmaps.py  add the spiral fieldmaps (no DICOM source) to fmap/
#   3. validate          run the BIDS validator on the staging dataset
#   4. (optional) merge  copy new subjects/sessions into the master
#                        NESTM_bids dataset
#
# Nothing is hardcoded per-subject: point it at a Flywheel export and it
# converts every H4M###[_T#] session it finds.
#
# ---- USAGE -----------------------------------------------------------------
#   ./run_all.sh <raw_root> <staging_out> [master_bids]
#
#   <raw_root>     the Flywheel export folder -- either the folder that
#                  directly contains SUBJECTS/, or anywhere above it
#   <staging_out>  where the freshly-converted BIDS data is built
#   [master_bids]  OPTIONAL. If given, newly-converted subjects/sessions are
#                  merged into this existing master dataset at the end (a
#                  subject already in the master dataset still gets any new
#                  timepoints it doesn't have yet -- see
#                  merge_into_nestm_bids.sh). Omit it to just build +
#                  validate the staging dataset and stop.
#
# EXAMPLES
#   # convert + validate only:
#   ./run_all.sh "~/pegasus/flywheel/nest-m" ~/pegasus/NESTM_staging
#
#   # convert + validate + merge into the master dataset:
#   ./run_all.sh "~/pegasus/flywheel/nest-m" ~/pegasus/NESTM_staging \
#                ~/pegasus/NESTM_bids
# ----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

RAW_ROOT="${1:?Usage: $0 <raw_root> <staging_out> [master_bids]}"
STAGING="${2:?Usage: $0 <raw_root> <staging_out> [master_bids]}"
MASTER="${3:-}"   # optional

echo "=============================================================="
echo " NEST-M conversion pipeline"
echo "   raw:      $RAW_ROOT"
echo "   staging:  $STAGING"
[ -n "$MASTER" ] && echo "   master:   $MASTER  (will merge at end)"
[ -z "$MASTER" ] && echo "   master:   (none -- convert + validate only)"
echo "=============================================================="

# ---- Step 1: convert ------------------------------------------------------
echo
echo ">>> Step 1/4: convert DICOMs to BIDS (dcm2bids)"
bash "$SCRIPT_DIR/convert_all.sh" "$RAW_ROOT" "$STAGING"

# ---- Step 2: fieldmaps ----------------------------------------------------
echo
echo ">>> Step 2/4: add spiral fieldmaps"
python3 "$SCRIPT_DIR/add_fieldmaps.py" "$STAGING"

# ---- Step 3: validate -----------------------------------------------------
echo
echo ">>> Step 3/4: validate staging dataset"
if command -v bids-validator-deno >/dev/null 2>&1; then
  # || true: the validator exits non-zero on the expected PARTICIPANT_ID
  # mismatch; we don't want that to abort the pipeline before the merge.
  bids-validator-deno "$STAGING" || true
else
  echo "  (bids-validator-deno not found -- skipping validation."
  echo "   install with: pip install bids-validator-deno)"
fi

# ---- Step 4: merge (optional) --------------------------------------------
if [ -n "$MASTER" ]; then
  echo
  echo ">>> Step 4/4: merge into master dataset"
  bash "$SCRIPT_DIR/merge_into_nestm_bids.sh" "$STAGING" "$MASTER"
  echo
  echo ">>> Re-validating merged master dataset"
  if command -v bids-validator-deno >/dev/null 2>&1; then
    bids-validator-deno "$MASTER" || true
  fi
else
  echo
  echo ">>> Step 4/4: merge skipped (no master dataset given)"
fi

echo
echo "=============================================================="
echo " Pipeline complete."
if [ -n "$MASTER" ]; then
  echo " New subjects/sessions are in: $MASTER"
  echo " Next: run fMRIPrep (see fmriPrep_preprocess.sh)."
else
  echo " Converted dataset is in: $STAGING"
  echo " Re-run with a 3rd argument (master dataset path) to merge."
fi
echo "=============================================================="
