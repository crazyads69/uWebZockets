#!/usr/bin/env sh
# Run the maintained-fork provenance checks for libxev, lsquic, and h1spec.
#
# Usage: check_dependency_forks.sh [--offline]

set -eu

script_dir=$(CDPATH='' cd "$(dirname "$0")" && pwd)

sh "$script_dir/check_libxev_fork.sh" "$@"
sh "$script_dir/check_lsquic_fork.sh" "$@"
sh "$script_dir/check_h1spec_fork.sh" "$@"
