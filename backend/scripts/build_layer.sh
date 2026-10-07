#!/usr/bin/env bash
# Builds the aggregate Lambda's runtime layer from backend/requirements-lock.txt,
# targeting python3.13 on arm64. Lambda layers put the layer's `python/`
# directory on sys.path, so dependencies are installed into
# backend/build/layer/python/.
#
# The lock pins the whole dependency tree with hashes, installed with
# --require-hashes. requirements.txt holds only the direct dependencies; after
# editing it, regenerate the lock from backend/ (uv is a dev-time tool only):
#   uv pip compile --python-version 3.13 --python-platform aarch64-manylinux2014 --generate-hashes requirements.txt -o requirements-lock.txt
# then regenerate requirements-dev.txt with the command in requirements-dev.in.
#
# Run this before `terraform plan` in infra/: the "layer" archive_file data
# source zips backend/build/layer/. That output directory is gitignored.
#
# boto3 is not packaged: the Lambda runtime already provides it.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# pip evaluates environment markers (e.g. python_version) against the running
# interpreter, not --python-version, so the host must match the Lambda runtime
# or the hashed lock no longer describes the full install.
if ! python3 -c 'import sys; sys.exit(sys.version_info[:2] != (3, 13))'; then
  echo "build_layer.sh: python3 must be Python 3.13 (the Lambda runtime)" >&2
  exit 1
fi

rm -rf build/layer

# --no-compile avoids shipping .pyc files compiled by the local interpreter.
python3 -m pip install \
  -r requirements-lock.txt \
  --require-hashes \
  --platform manylinux2014_aarch64 \
  --implementation cp \
  --python-version 3.13 \
  --only-binary=:all: \
  --no-compile \
  --target build/layer/python
