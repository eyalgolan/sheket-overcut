#!/usr/bin/env bash
# Builds the aggregate Lambda's runtime layer from backend/requirements.txt,
# targeting python3.13 on arm64. Lambda layers put the layer's `python/`
# directory on sys.path, so dependencies are installed into
# backend/build/layer/python/.
#
# Run this before `terraform plan` in infra/: the "layer" archive_file data
# source zips backend/build/layer/. That output directory is gitignored.
#
# boto3 is not packaged: the Lambda runtime already provides it.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

rm -rf build/layer

# --no-compile avoids shipping .pyc files compiled by the local interpreter.
python3 -m pip install \
  -r requirements.txt \
  --platform manylinux2014_aarch64 \
  --implementation cp \
  --python-version 3.13 \
  --only-binary=:all: \
  --no-compile \
  --target build/layer/python
