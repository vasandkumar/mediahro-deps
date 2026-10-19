# windows sub-lane (lane B4)

Builds every library in ../versions.json that applies to windows with the flags in ../flags/, stages lib/, include/ and licenses/, then runs: python ../scripts/package.py <target> <staging> <out-dir>

Entry point: build.sh <out-dir> (written by this sub-lane; targets in ../README.md).
