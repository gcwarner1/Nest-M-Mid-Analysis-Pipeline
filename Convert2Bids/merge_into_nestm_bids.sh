#!/usr/bin/env bash
# merge_into_nestm_bids.sh
#
# Copies newly-converted sub-*/ses-* folders from a staging BIDS dataset into
# the master NESTM_bids dataset, then (re)builds participants.tsv from
# whatever sub-* folders exist in the master dataset.
#
# Unlike a simple "skip the whole subject if it already exists" merge, this
# is SESSION-aware: NEST-M subjects get re-scanned across up to 4 timepoints
# over time, so a subject that's already in the master dataset (e.g. with
# ses-T1 and ses-T2) still needs its new ses-T3 merged in when that timepoint
# is converted later. A session that already exists in the target is never
# overwritten -- it's flagged so you can resolve it by hand.
#
# Usage:
#   ./merge_into_nestm_bids.sh /path/to/staging_bids /path/to/NESTM_bids

set -euo pipefail

NEW_BIDS="${1:?Usage: $0 <staging_bids_dataset> <target_NESTM_bids>}"
TARGET_BIDS="${2:?Usage: $0 <staging_bids_dataset> <target_NESTM_bids>}"

if [ ! -d "$NEW_BIDS" ]; then
  echo "Staging dataset not found: $NEW_BIDS"
  exit 1
fi
if [ ! -d "$TARGET_BIDS" ]; then
  echo "Target dataset not found: $TARGET_BIDS"
  exit 1
fi

echo "Merging $NEW_BIDS into $TARGET_BIDS ..."

n_new_subjects=0
n_new_sessions=0
n_skipped_sessions=0

shopt -s nullglob
for sub_dir in "$NEW_BIDS"/sub-*/; do
  sub="$(basename "$sub_dir")"
  target_sub_dir="$TARGET_BIDS/$sub"

  if [ ! -e "$target_sub_dir" ]; then
    cp -R "$sub_dir" "$target_sub_dir"
    n_ses=$(find "$sub_dir" -mindepth 1 -maxdepth 1 -type d -name 'ses-*' | wc -l | tr -d ' ')
    echo "  copied new subject $sub ($n_ses session(s))"
    n_new_subjects=$((n_new_subjects + 1))
    n_new_sessions=$((n_new_sessions + n_ses))
    continue
  fi

  # Subject already exists in the target -- merge in only the sessions it
  # doesn't have yet.
  ses_found=0
  for ses_dir in "$sub_dir"ses-*/; do
    [ -d "$ses_dir" ] || continue
    ses_found=1
    ses="$(basename "$ses_dir")"
    target_ses_dir="$target_sub_dir/$ses"
    if [ -e "$target_ses_dir" ]; then
      echo "  !! $sub/$ses already exists in $TARGET_BIDS -- NOT overwriting. Resolve manually."
      n_skipped_sessions=$((n_skipped_sessions + 1))
      continue
    fi
    cp -R "$ses_dir" "$target_ses_dir"
    echo "  copied new session $sub/$ses (subject already existed in target)"
    n_new_sessions=$((n_new_sessions + 1))
  done
  if [ "$ses_found" -eq 0 ]; then
    echo "  !! $sub in staging has no ses-* folders -- nothing to merge (unexpected)"
  fi
done

PARTS="$TARGET_BIDS/participants.tsv"
echo "Rebuilding $PARTS ..."
echo -e "participant_id" > "$PARTS.new"
for sub_dir in "$TARGET_BIDS"/sub-*/; do
  echo -e "$(basename "$sub_dir")" >> "$PARTS.new"
done
mv "$PARTS.new" "$PARTS"
n=$(($(wc -l < "$PARTS") - 1))

echo
echo "Merge summary: $n_new_subjects new subject(s), $n_new_sessions new session(s) added, $n_skipped_sessions session(s) skipped (already existed)."
echo "Wrote $PARTS with $n participants."
echo
echo "participants.tsv only has the participant_id column for now -- add age/sex/group"
echo "columns whenever you have that data handy; the validator only requires participant_id."
echo
echo "Next: run the BIDS validator on $TARGET_BIDS before pointing fMRIPrep at it."
