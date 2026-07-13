#!/usr/bin/env python3
"""
add_fieldmaps.py

The "spiral high-res fieldmap" series has NO DICOM in the NEST-M Flywheel
export -- only two pre-exported .nii.gz files per acquisition (a magnitude
image and an already-computed real fieldmap in Hz). dcm2bids/dcm2niix has
nothing to work with there, so this script handles fieldmaps on its own,
AFTER convert_all.sh (dcm2bids) has run for everything else.

It auto-discovers subjects/sessions -- nothing is hardcoded. For every
sub-*/ses-* folder that dcm2bids already produced in the BIDS output, it
looks up the matching raw SESSIONS/<label> folder recorded by convert_all.sh
in tmp_dcm2bids/session_map.tsv (convert_all.sh already resolved the messy
subject-folder naming and the ambiguous-session checks -- no need to redo
that here), locates the "spiral high-res fieldmap" acquisition(s) inside
ACQUISITIONS/, and:

  1. Copies the two raw .nii.gz files into fmap/, renamed to BIDS
     convention. This is a "Case 3" direct field map (one magnitude image,
     one real fieldmap in Hz, no second echo) -- the correct BIDS suffix for
     the magnitude image is "magnitude" (no trailing number; "magnitude1" is
     only for the two-magnitude phase-difference case, which this isn't).
  2. Squeezes the magnitude image to 3D before writing it -- BIDS requires
     magnitude images to be exactly 3D. In this dataset the raw files are
     shaped (256, 256, 45, 2, 1): a trailing singleton plus a genuine
     dual-echo dimension. The script drops the singleton and takes the first
     echo as the magnitude reference (logged). If a file's shape doesn't
     match this pattern, it warns and copies as-is rather than guessing.
  3. Writes a JSON sidecar for the fieldmap file with "Units": "Hz" (there's
     no DICOM to inherit metadata from -- this is the one field we know from
     the protocol).
  4. Computes "IntendedFor": each BOLD run gets whichever fieldmap was
     acquired most recently before it, using the scan number embedded in the
     raw filenames (fieldmap side) and the SeriesNumber dcm2niix wrote into
     each func/*_bold.json (BOLD side).

If a session has two fieldmap acquisitions (a mid-session re-shim), they
come out as fmap/..._run-1_... and ..._run-2_..., split by the rule in #4.

Usage:
    python add_fieldmaps.py <bids_staging_out>
Example:
    python add_fieldmaps.py ~/pegasus/NESTM_staging

Note: unlike the very first version of this script, <raw_root> is no longer
a separate argument -- convert_all.sh already recorded the exact raw session
path for every sub-*/ses-* it converted in tmp_dcm2bids/session_map.tsv
inside the staging output, so this script reads that instead of re-deriving
raw paths from the (messy, inconsistently-cased) NEST-M folder names.
"""
import json
import sys
import os
import re
import shutil
import glob

try:
    import numpy as np
    import nibabel as nib
except ImportError:
    print("This script needs numpy and nibabel to process the magnitude images.")
    print("Install with: pip install numpy nibabel")
    sys.exit(1)

# Name of the fieldmap series folder in the raw export. The trailing
# _1/_2/... variants (from Flywheel duplicate numbering, e.g. a re-shim) are
# matched too.
FMAP_FOLDER_RE = re.compile(r"^spiral high-res fieldmap(_\d+)?$", re.IGNORECASE)


def scan_number_from_stem(stem):
    # stem basename looks like "33308_6_1" -> scan number is the middle int (6)
    base = os.path.basename(stem)
    parts = base.split("_")
    return int(parts[-2])


def series_number(json_path):
    with open(json_path) as f:
        data = json.load(f)
    return data.get("SeriesNumber", data.get("AcquisitionNumber"))


def load_session_map(bids_root):
    """Read tmp_dcm2bids/session_map.tsv written by convert_all.sh:
    columns are sub, ses, raw SESSIONS/<label> dir (absolute path)."""
    path = os.path.join(bids_root, "tmp_dcm2bids", "session_map.tsv")
    mapping = {}
    if not os.path.exists(path):
        print(f"!! session map not found at {path} -- did convert_all.sh run "
              f"first (in this same staging output)?")
        return mapping
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split("\t")
            if len(parts) != 3:
                continue
            sub, ses, raw_session_dir = parts
            mapping[(sub, ses)] = raw_session_dir
    return mapping


def find_fmap_stems(session_dir):
    """session_dir = raw SESSIONS/<label> folder. Return a list of raw
    fieldmap 'stems' (full path minus the .nii.gz / _fieldmap.nii.gz
    suffix), one per fieldmap acquisition found under
    ACQUISITIONS/<fmap-folder>/FILES/."""
    stems = []
    acq_root = os.path.join(session_dir, "ACQUISITIONS")
    if not os.path.isdir(acq_root):
        return stems
    for entry in sorted(os.listdir(acq_root)):
        entry_path = os.path.join(acq_root, entry)
        if os.path.isdir(entry_path) and FMAP_FOLDER_RE.match(entry):
            files_dir = os.path.join(entry_path, "FILES")
            fm_files = glob.glob(os.path.join(files_dir, "*_fieldmap.nii.gz"))
            for fm in fm_files:
                stem = fm[: -len("_fieldmap.nii.gz")]
                stems.append(stem)
    return stems


def main(bids_root):
    # Auto-discover every sub-*/ses-* that dcm2bids produced.
    sessions = []
    for sub_dir in sorted(glob.glob(os.path.join(bids_root, "sub-*"))):
        sub = os.path.basename(sub_dir)
        for ses_dir in sorted(glob.glob(os.path.join(sub_dir, "ses-*"))):
            ses = os.path.basename(ses_dir)
            sessions.append((sub, ses))

    if not sessions:
        print(f"No sub-*/ses-* folders found in {bids_root}. "
              f"Did convert_all.sh run first?")
        return

    session_map = load_session_map(bids_root)

    for sub, ses in sessions:
        ses_dir = os.path.join(bids_root, sub, ses)
        fmap_dir = os.path.join(ses_dir, "fmap")
        func_dir = os.path.join(ses_dir, "func")

        if not os.path.isdir(func_dir):
            print(f"!! {sub}/{ses}: no func/ folder -- skipping (no BOLD to map to)")
            continue

        session_dir = session_map.get((sub, ses))
        if session_dir is None:
            print(f"!! {sub}/{ses}: not found in session_map.tsv (was it converted "
                  f"in this staging run?), skipping fieldmaps")
            continue
        if not os.path.isdir(session_dir):
            print(f"!! {sub}/{ses}: recorded raw folder {session_dir} no longer "
                  f"exists, skipping fieldmaps")
            continue

        stems = find_fmap_stems(session_dir)
        if not stems:
            print(f"!! {sub}/{ses}: no 'spiral high-res fieldmap' folder found "
                  f"in {session_dir}/ACQUISITIONS, skipping")
            continue

        os.makedirs(fmap_dir, exist_ok=True)
        multi = len(stems) > 1
        fmap_scan_numbers = []  # (scan_number, fieldmap_json_path)

        for stem in sorted(stems, key=scan_number_from_stem):
            mag_src = stem + ".nii.gz"
            fm_src = stem + "_fieldmap.nii.gz"

            if not os.path.exists(mag_src) or not os.path.exists(fm_src):
                print(f"!! {sub}/{ses}: expected files not found next to {stem}, "
                      f"skipping this fieldmap")
                continue

            # run index (for multi-fieldmap sessions) based on scan-number order
            if multi:
                idx = sorted(stems, key=scan_number_from_stem).index(stem) + 1
                run_tag = f"_run-{idx}"
            else:
                run_tag = ""

            mag_dst = os.path.join(fmap_dir, f"{sub}_{ses}{run_tag}_magnitude.nii.gz")
            fm_dst = os.path.join(fmap_dir, f"{sub}_{ses}{run_tag}_fieldmap.nii.gz")
            fm_json_dst = os.path.join(fmap_dir, f"{sub}_{ses}{run_tag}_fieldmap.json")

            img = nib.load(mag_src)
            data = np.squeeze(img.get_fdata())  # drop trailing singleton dims

            if data.ndim == 3:
                squeezed = nib.Nifti1Image(data, img.affine, img.header)
                squeezed.header.set_data_shape(data.shape)
                nib.save(squeezed, mag_dst)
                print(f"{sub}/{ses}: squeezed {os.path.basename(mag_src)} "
                      f"from {img.shape} to {data.shape}")
            elif data.ndim == 4 and data.shape[3] == 2:
                # Dual-echo GE field map bundled into one file. The separate
                # precomputed _fieldmap.nii.gz drives distortion correction;
                # this magnitude image is a registration reference, so echo 1
                # (shorter TE) is a reasonable default. Logged explicitly.
                vol0 = data[..., 0]
                squeezed = nib.Nifti1Image(vol0, img.affine, img.header)
                squeezed.header.set_data_shape(vol0.shape)
                nib.save(squeezed, mag_dst)
                print(f"{sub}/{ses}: {os.path.basename(mag_src)} had shape "
                      f"{img.shape} (dual-echo) -- took echo 1 of 2, "
                      f"wrote {vol0.shape}")
            else:
                print(f"!! {sub}/{ses}: {mag_src} has shape {img.shape} -- "
                      f"doesn't match the expected dual-echo pattern. "
                      f"NOT auto-picking a volume; copying as-is, fix by hand.")
                shutil.copy2(mag_src, mag_dst)

            shutil.copy2(fm_src, fm_dst)
            print(f"{sub}/{ses}: copied {os.path.basename(mag_dst)}, "
                  f"{os.path.basename(fm_dst)}")

            fmap_scan_numbers.append((scan_number_from_stem(stem), fm_json_dst))

        if not fmap_scan_numbers:
            continue

        fmap_scan_numbers.sort()

        # Assign each BOLD run to the nearest-preceding fieldmap.
        intended = {j: [] for _, j in fmap_scan_numbers}
        bold_jsons = sorted(glob.glob(os.path.join(func_dir, "*_bold.json")))
        for bj in bold_jsons:
            bn = series_number(bj)
            if bn is None:
                print(f"  ! no SeriesNumber in {bj}, skipping this run")
                continue
            preceding = [(n, j) for n, j in fmap_scan_numbers if n < bn]
            target = max(preceding, default=fmap_scan_numbers[0])[1]
            bold_nii = bj[: -len(".json")] + ".nii.gz"
            rel = f"bids::{sub}/{ses}/func/{os.path.basename(bold_nii)}"
            intended[target].append(rel)

        for _, fm_json_dst in fmap_scan_numbers:
            with open(fm_json_dst, "w") as f:
                json.dump({
                    "Units": "Hz",
                    "IntendedFor": intended[fm_json_dst],
                }, f, indent=4)
            print(f"{sub}/{ses}: {os.path.basename(fm_json_dst)} -> "
                  f"IntendedFor {len(intended[fm_json_dst])} run(s)")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(1)
    main(sys.argv[1])
