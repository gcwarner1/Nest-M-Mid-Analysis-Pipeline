#!/bin/bash

# =========================
# HOW TO USE
# 
# First, make sure the data you want to preprocess is in BIDS format and has all necessary json files.
# After that, set the bids_root_dir variable to the full path to the directory contianing the bids data.
# Note that as this script uses $HOME variables it will likely only work if being run by the braveDP user.
# Set the subj variable to a string of the subject IDs you want to analyze separated by spaces. Make sure the spelling matches the directory tree.
# Run this script using the following terminal command.
#       bash fmriPrep_preprocess.sh
# =========================


# =========================
# User inputs
# =========================

#Set path to data you wish to bids formatted data you with to preprocess (e.g. $HOME/Desktop/NESTM_bids)
bids_root_dir=$HOME/pegasus/NEST-M/NESTM_bids

#Set subject IDs you wish to preprocess in a single string separated by spaces (if preprocessing multiple subejcts at once e.g. "sub_H4M001 sub_H4M002"
subj="H7A008 H7A010 H7A011 H7A012"

# =========================
# Auto-calculate resources
# Hardcoded for M1 Ultra Mac Studio (65 GB, 20 threads)
# =========================

USABLE_MEM_GB=50    # 65 GB total - 8 GB reserved for OS
USABLE_THREADS=18   # 20 cores total - 2 reserved for OS

# Count subjects from the subj string
read -ra subj_array <<< "$subj"
n_subjects=${#subj_array[@]}

# Divide usable resources across subjects
nthreads=$(( USABLE_THREADS / n_subjects ))
mem_gb=$(( USABLE_MEM_GB / n_subjects ))

# Enforce minimums
(( nthreads < 1 )) && nthreads=1
(( mem_gb   < 4 )) && mem_gb=4

# Convert GB to MB and subtract 5000 MB buffer
mem_mb=$(( (mem_gb * 1000) - 5000 ))

echo "Subjects: ${n_subjects} | Threads/subject: ${nthreads} | Mem/subject: ${mem_gb} GB (${mem_mb} MB)"

# =========================
# FreeSurfer license
# =========================

export FS_LICENSE=$HOME/Desktop/license.txt

# =========================
# Create derivatives directory if needed
# =========================

mkdir -p $bids_root_dir/derivatives
mkdir -p $HOME/pegasus/fmriprep_work

# =========================
# Run fMRIPrep via Docker
# =========================
# NOTE: -w must be bind-mounted with -v just like /data and /out are, and
# should point at the container-internal path (/work), not a host path
# string. Without the -v line below, "-w ~/pegasus/fmriprep_work" expands
# to a literal macOS-style path on the host shell, but the container has no
# mount there -- fMRIPrep then silently creates that path INSIDE the
# container's own ephemeral filesystem instead of on the actual Pegasus
# volume, which is what filled up Docker's VM disk and crashed Docker
# Desktop previously.

docker run --rm -it \
--platform linux/amd64 \
-v $bids_root_dir:/data:ro \
-v $bids_root_dir/derivatives:/out \
-v $FS_LICENSE:/opt/freesurfer/license.txt:ro \
-v $HOME/pegasus/fmriprep_work:/work \
nipreps/fmriprep:25.2.5 \
/data /out participant \
--participant-label $subj \
--skip-bids-validation \
--md-only-boilerplate \
--fs-no-reconall \
--bold2anat-init t1w \
--output-spaces MNI152NLin2009cAsym:res-2 \
--nthreads $nthreads \
--stop-on-first-crash \
--mem_mb $mem_mb \
-w /work
