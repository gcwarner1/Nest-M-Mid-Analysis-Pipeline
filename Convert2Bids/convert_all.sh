#!/usr/bin/env bash
# convert_all.sh
#
# Converts a NEST-M Flywheel export into BIDS format. Auto-discovers every
# subject/session under the raw root -- no subject IDs are hardcoded, so this
# works for every subject as they're collected, without editing the script.
#
# Expected raw layout (this is the literal Flywheel CLI/GUI export -- a
# mirror of the project's container hierarchy, NOT a flat folder):
#   <raw_root>/
#     [nest-m/]                       <- optional wrapper folder, either name is fine
#       SUBJECTS/
#         H4M014_T1/                 <- subject folder: H4M<3 digits>[_T<digit>]
#           SESSIONS/
#             <numeric session id or "unknown">/   <- exactly ONE subfolder
#               ACQUISITIONS/
#                 T1w 1mm/FILES/*.dicom.zip
#                 conscious 2/FILES/*.dicom.zip
#                 ... etc
#         H4M014_T2/
#         H4M015_T1/
#         ...
#
# <raw_root> can point at the folder that directly contains SUBJECTS/, or
# anywhere above it (e.g. the Flywheel export root) -- this script searches
# a few levels down to find it.
#
# RESUMABLE / SAFE TO RE-RUN:
#   - If sub-*/ses-* already exists (and is non-empty) in the BIDS staging
#     output, that session is SKIPPED -- it is not re-unzipped or re-run
#     through dcm2bids. Only genuinely new sessions get converted. This is
#     checked per SESSION, not per subject, since a subject can have some
#     timepoints already converted and others not.
#   - Ambiguous or broken sessions (see below) no longer abort the whole
#     run. They're logged loudly, skipped, and the run continues with the
#     next subject/session. Every skipped/problem session is collected and
#     printed as a single "Failed to process" list at the very end, so
#     nothing needing attention gets lost in the scrollback.
#
# Behaviour (per the lab's chosen rules):
#   - Subject folders are matched case-insensitively against H4M###[_T#]. A
#     folder with no _T# suffix is treated as timepoint 1. Anything that
#     doesn't match (typos, test/phantom folders, "H4M001redo"-style stray
#     folders, etc.) is WARNED about and SKIPPED -- these aren't real
#     subject data, so they're not counted as failures needing attention.
#   - If a subject/timepoint's SESSIONS/ folder contains more than one
#     session subfolder (e.g. a duplicated scan, or a re-shim session mixed
#     in), that session is logged as AMBIGUOUS with both subfolders'
#     acquisition lists printed, then skipped -- added to the final "Failed
#     to process" list for a human to resolve by hand.
#   - If a different raw subject folder maps to a sub/ses that was ALREADY
#     converted earlier in this SAME run (possible because matching is
#     case-insensitive, e.g. stray duplicate exports like "h4m001_t3" and
#     "H4M001_T3" both existing), that's flagged as a DUPLICATE rather than
#     a normal "already converted" skip, since it likely means stray/
#     duplicate raw data rather than a normal resume. Also added to the
#     final "Failed to process" list.
#   - Only the series this pipeline actually converts (T1w, T2w, DTI,
#     conscious/nonconscious, Cue_Reactivity, MID runs) get unzipped.
#     Localizer and GE HOS FOV28 calibration scans are skipped entirely to
#     save time/disk -- dcm2bids would ignore them anyway since they match
#     nothing in dcm2bids_config.json. The spiral fieldmap has no DICOM (see
#     add_fieldmaps.py) so it's never unzipped here either.
#
# Also maintains tmp_dcm2bids/session_map.tsv (sub, ses, raw SESSIONS/<label>
# path) so add_fieldmaps.py doesn't have to re-derive raw paths itself. This
# file is never wiped on re-run -- it only grows -- so add_fieldmaps.py can
# still find the raw path for a session that was converted in an earlier run
# (including sessions converted before this resume feature existed, which
# get their row backfilled the first time this script sees them already
# converted).
#
# Usage:
#   ./convert_all.sh <raw_root> <bids_staging_out>
# Example:
#   ./convert_all.sh "/Volumes/Pegasus32 R8/flywheel/nest-m" \
#                    /Users/braveDP/Desktop/NESTM_staging

set -euo pipefail

RAW_ROOT="${1:?Usage: $0 <raw_root> <bids_staging_out>}"
BIDS_OUT="${2:?Usage: $0 <raw_root> <bids_staging_out>}"
CONFIG="$(cd "$(dirname "$0")" && pwd)/dcm2bids_config.json"

if [ ! -d "$RAW_ROOT" ]; then
  echo "ERROR: raw root not found: $RAW_ROOT" >&2
  exit 1
fi
if [ ! -f "$CONFIG" ]; then
  echo "ERROR: dcm2bids_config.json not found next to this script ($CONFIG)" >&2
  exit 1
fi

# --- locate the SUBJECTS/ folder (the Flywheel export mirrors the full
#     group/project/SUBJECTS/... container hierarchy) ------------------------
if [ "$(basename "$RAW_ROOT")" = "SUBJECTS" ]; then
  SUBJECTS_DIR="$RAW_ROOT"
else
  SUBJECTS_DIR="$(find "$RAW_ROOT" -maxdepth 4 -type d -name SUBJECTS 2>/dev/null | head -n1)"
fi
if [ -z "${SUBJECTS_DIR:-}" ] || [ ! -d "$SUBJECTS_DIR" ]; then
  echo "ERROR: could not find a SUBJECTS folder under $RAW_ROOT" >&2
  echo "       Expected the Flywheel export layout .../SUBJECTS/<subject>/SESSIONS/<session>/ACQUISITIONS/<series>/FILES" >&2
  exit 1
fi

mkdir -p "$BIDS_OUT"
if [ ! -f "$BIDS_OUT/dataset_description.json" ]; then
  dcm2bids_scaffold -o "$BIDS_OUT"
fi

TMP_DIR="$BIDS_OUT/tmp_dcm2bids"
mkdir -p "$TMP_DIR"
SESSION_MAP="$TMP_DIR/session_map.tsv"
touch "$SESSION_MAP"

SUBJECT_RE='^[Hh]4[Mm]([0-9]{3})(_[Tt]([0-9]))?$'

WANTED_SERIES_RE='^(T1w 1mm|T2w CUBE \.8mm sag|conscious 2|nonconscious 2|Cue_Reactivity|MID_run1_BOLD|MID_run2_BOLD|DTI 2mm b1250 84dir\(axial\))(_[0-9]+)?$'

n_processed=0
n_already=0
n_not_subject=0
FAILED_ITEMS=()
THIS_RUN_SESSIONS=()

already_done_this_run() {
  local want="$1"
  local entry
  for entry in "${THIS_RUN_SESSIONS[@]:-}"; do
    if [ "${entry%%::*}" = "$want" ]; then
      return 0
    fi
  done
  return 1
}

source_folder_for_key() {
  local want="$1"
  local entry
  for entry in "${THIS_RUN_SESSIONS[@]:-}"; do
    if [ "${entry%%::*}" = "$want" ]; then
      echo "${entry#*::}"
      return 0
    fi
  done
  echo "?"
}

session_map_has_row() {
  local want_sub="$1"
  local want_ses="$2"
  local s se
  if [ ! -f "$SESSION_MAP" ]; then
    return 1
  fi
  while IFS=$'\t' read -r s se _; do
    if [ "$s" = "$want_sub" ] && [ "$se" = "$want_ses" ]; then
      return 0
    fi
  done < "$SESSION_MAP"
  return 1
}

shopt -s nullglob
for subj_path in "$SUBJECTS_DIR"/*/; do
  folder="$(basename "$subj_path")"

  if [[ ! "$folder" =~ $SUBJECT_RE ]]; then
    echo "  !! SKIPPING '$folder' -- does not match expected NEST-M pattern H4M###[_T#]"
    n_not_subject=$((n_not_subject + 1))
    continue
  fi

  digits="${BASH_REMATCH[1]}"
  tp="${BASH_REMATCH[3]:-1}"
  sub="H4M${digits}"
  ses="T${tp}"
  key="sub-${sub}_ses-${ses}"

  if already_done_this_run "$key"; then
    earlier_folder="$(source_folder_for_key "$key")"
    echo ""
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "!! DUPLICATE: raw folder '$folder' also maps to sub-$sub/ses-$ses,"
    echo "!! which was ALREADY converted earlier in THIS run (from raw"
    echo "!! folder '$earlier_folder'). This looks like duplicate/stray raw"
    echo "!! data, not a normal resume. SKIPPING '$folder' -- resolve by hand."
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo ""
    FAILED_ITEMS+=("sub-$sub/ses-$ses ($folder) -- DUPLICATE: also produced by '$earlier_folder' earlier in this run")
    continue
  fi

  target_ses_dir="$BIDS_OUT/sub-$sub/ses-$ses"
  if [ -d "$target_ses_dir" ] && [ -n "$(find "$target_ses_dir" -mindepth 1 -print -quit 2>/dev/null)" ]; then
    echo "  -- sub-$sub/ses-$ses already exists in $BIDS_OUT -- skipping (already converted)"
    n_already=$((n_already + 1))
    if ! session_map_has_row "$sub" "$ses"; then
      cand_sessions_dir="${subj_path}SESSIONS"
      if [ -d "$cand_sessions_dir" ]; then
        cand_subdirs=()
        while IFS= read -r -d '' d; do
          cand_subdirs+=("$d")
        done < <(find "$cand_sessions_dir" -mindepth 1 -maxdepth 1 -type d -print0)
        if [ "${#cand_subdirs[@]}" -eq 1 ]; then
          printf '%s\t%s\t%s\n' "$sub" "$ses" "${cand_subdirs[0]}" >> "$SESSION_MAP"
        fi
      fi
    fi
    THIS_RUN_SESSIONS+=("${key}::${folder}")
    continue
  fi

  sessions_dir="${subj_path}SESSIONS"
  if [ ! -d "$sessions_dir" ]; then
    echo "  !! SKIPPING sub-$sub/ses-$ses ($folder) -- no SESSIONS folder found inside it"
    FAILED_ITEMS+=("sub-$sub/ses-$ses ($folder) -- no SESSIONS folder found")
    continue
  fi

  session_subdirs=()
  while IFS= read -r -d '' d; do
    session_subdirs+=("$d")
  done < <(find "$sessions_dir" -mindepth 1 -maxdepth 1 -type d -print0)

  if [ "${#session_subdirs[@]}" -eq 0 ]; then
    echo "  !! SKIPPING sub-$sub/ses-$ses ($folder) -- no session subfolder found inside SESSIONS/"
    FAILED_ITEMS+=("sub-$sub/ses-$ses ($folder) -- no session subfolder found inside SESSIONS/")
    continue
  fi

  if [ "${#session_subdirs[@]}" -gt 1 ]; then
    echo ""
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "!! AMBIGUOUS: '$folder' contains multiple SESSIONS subfolders:"
    labels=()
    for d in "${session_subdirs[@]}"; do
      label="$(basename "$d")"
      labels+=("$label")
      acqs="$(find "$d/ACQUISITIONS" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | xargs -n1 basename 2>/dev/null | sort | paste -sd, - || true)"
      echo "!!    - $label  ($acqs)"
    done
    echo "!! This is ambiguous (possible duplicate/redo scan at export)."
    echo "!! SKIPPING sub-$sub/ses-$ses ($folder) -- resolve by hand (keep the"
    echo "!! correct session subfolder, remove/rename the other), then re-run"
    echo "!! to pick it up. The rest of the batch will keep processing."
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo ""
    label_list=""
    for l in "${labels[@]}"; do
      if [ -z "$label_list" ]; then
        label_list="$l"
      else
        label_list="$label_list, $l"
      fi
    done
    FAILED_ITEMS+=("sub-$sub/ses-$ses ($folder) -- ambiguous: ${#session_subdirs[@]} session folders ($label_list)")
    continue
  fi

  session_dir="${session_subdirs[0]}"
  acq_root="$session_dir/ACQUISITIONS"
  extract_dir="$TMP_DIR/extracted_raw/${sub}_ses-${ses}"

  echo "=== $sub ses-$ses (raw: SUBJECTS/$folder/SESSIONS/$(basename "$session_dir")) ==="

  mkdir -p "$extract_dir"
  if [ -d "$acq_root" ]; then
    for acq_dir in "$acq_root"/*/; do
      acq_name="$(basename "$acq_dir")"
      if [[ ! "$acq_name" =~ $WANTED_SERIES_RE ]]; then
        continue
      fi
      files_dir="${acq_dir}FILES"
      if [ ! -d "$files_dir" ]; then
        continue
      fi
      while IFS= read -r -d '' zipfile; do
        unzip -o -q "$zipfile" -d "$extract_dir"
      done < <(find "$files_dir" -iname "*.dicom.zip" -print0)
    done
  fi

  if [ -z "$(find "$extract_dir" -iname "*.dcm" -print -quit)" ]; then
    echo "  !! no .dcm files found after unzipping -- check the raw data for $folder"
    FAILED_ITEMS+=("sub-$sub/ses-$ses ($folder) -- no .dcm files found after unzipping (check raw data)")
    continue
  fi

  dcm2bids -d "$extract_dir" -p "$sub" -s "$ses" -c "$CONFIG" -o "$BIDS_OUT" --force_dcm2bids
  printf '%s\t%s\t%s\n' "$sub" "$ses" "$session_dir" >> "$SESSION_MAP"
  THIS_RUN_SESSIONS+=("${key}::${folder}")
  n_processed=$((n_processed + 1))
done

echo
echo "convert_all.sh done:"
echo "  $n_processed session(s) newly converted"
echo "  $n_already session(s) already converted -- skipped"
echo "  $n_not_subject folder(s) skipped -- don't match the H4M###[_T#] naming pattern"
echo "  ${#FAILED_ITEMS[@]} session(s) failed to process"

if [ "${#FAILED_ITEMS[@]}" -gt 0 ]; then
  echo
  echo "=============================================================="
  echo "Failed to process (${#FAILED_ITEMS[@]}) -- these need attention:"
  for item in "${FAILED_ITEMS[@]}"; do
    echo "  - $item"
  done
  echo "=============================================================="
fi

if [ "$n_processed" -eq 0 ] && [ "$n_already" -eq 0 ]; then
  echo "  (Nothing was converted -- check that $SUBJECTS_DIR contains H4M###[_T#] folders.)"
fi
