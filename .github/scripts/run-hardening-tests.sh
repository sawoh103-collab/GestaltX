#!/usr/bin/env bash
# Compile and execute every repository hardening test before packaging. The
# manifests make a newly added test fail CI until it is assigned a complete
# source set or runner here.
set -euo pipefail
shopt -s nullglob

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

command -v xcrun >/dev/null 2>&1 || { echo "Error: xcrun is required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "Error: python3 is required" >&2; exit 1; }

echo "==> WorkflowPinning"
python3 - <<'VERIFY_WORKFLOW'
from pathlib import Path
import re

workflow = Path(".github/workflows/build.yml").read_text(encoding="utf-8")
expected = {
    "actions/checkout": ("3d3c42e5aac5ba805825da76410c181273ba90b1", 2),
    "actions/upload-artifact": ("cf430e030ddbb5b0abf93d22962f4752f3646cd9", 1),
    "maxim-lobanov/setup-xcode": ("ed7a3b1fda3918c0306d1b724322adc0b8cc0a90", 1),
}
specifications = re.findall(r"^\s*uses:\s*([^#\r\n]+?)\s*$", workflow, re.MULTILINE)
uses = []
errors = []
for specification in specifications:
    if specification.startswith("./"):
        continue
    match = re.fullmatch(r"([^@\s]+)@([0-9a-f]{40})", specification)
    if match is None:
        errors.append(f"external action is not pinned to a full commit SHA: {specification}")
        continue
    uses.append(match.groups())
for action, (sha, count) in expected.items():
    actual = [ref for name, ref in uses if name == action]
    if actual != [sha] * count:
        errors.append(f"{action} expected {count} use(s) at {sha}; found {actual}")
if not re.search(r"^\s*xcode-version:\s*['\"]?27\.2['\"]?\s*$", workflow, re.MULTILINE):
    errors.append("setup-xcode must select Xcode 27.2")
if errors:
    raise SystemExit("Workflow pinning check failed:\n- " + "\n- ".join(errors))
print("PASS: every external action uses a full SHA and required actions/Xcode are pinned.")
VERIFY_WORKFLOW

build_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/gestaltx-tests.XXXXXX")"
manifest="$build_dir/swift-tests.txt"
trap 'rm -rf "$build_dir"' EXIT

document_sources=(
  GestaltX/GestaltDocument.swift
  GestaltX/MobileGestaltCacheLayout.swift
  GestaltX/DeviceCacheOptions.swift
  GestaltX/Capabilities.swift
)
inbox_sources=(Shared/SharedPlistInbox.swift)
device_bound_sources=(
  "${document_sources[@]}"
  "${inbox_sources[@]}"
  GestaltX/DeviceBoundPlist.swift
)

run_with_timeout() {
  python3 - "$1" <<'PY'
import subprocess
import sys

try:
    subprocess.run([sys.argv[1]], check=True, timeout=60)
except subprocess.TimeoutExpired:
    raise SystemExit(f"Error: test timed out after 60 seconds: {sys.argv[1]}")
PY
}

run_swift_test() {
  local test="$1"
  shift
  local name="${test##*/}"
  name="${name%.swift}"
  echo "==> $name"
  xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library "$@" "$test" -o "$build_dir/$name"
  run_with_timeout "$build_dir/$name"
  printf '%s\n' "$test" >> "$manifest"
}

document_tests=(
  tests/ArtworkPreservationTests.swift
  tests/BackupDeletionTests.swift
  tests/BackupIntegrityTests.swift
  tests/BackupLayoutTests.swift
  tests/CapabilityCatalogTests.swift
  tests/DeviceIdentityEditTests.swift
  tests/DynamicIslandRestorationTests.swift
  tests/FieldValuePrecisionTests.swift
  tests/IntegerValueTests.swift
  tests/LocalRestoreProvenanceTests.swift
  tests/MalformedCacheDescriptorTests.swift
  tests/OriginalCacheGenerationTests.swift
  tests/OriginalHistoryMigrationTests.swift
  tests/SystemWriteRecoveryTests.swift
  tests/UnchangedRestoreTests.swift
)
for test in "${document_tests[@]}"; do
  run_swift_test "$test" "${document_sources[@]}"
done

run_swift_test tests/DocumentTests.swift "${document_sources[@]}" tests/WAPITests.swift
printf '%s\n' tests/WAPITests.swift >> "$manifest"

for test in \
  tests/BackupExportProofTests.swift \
  tests/DeviceBoundPlistTests.swift \
  tests/NonFinitePlistTests.swift \
  tests/SharedPlistInboxTests.swift; do
  run_swift_test "$test" "${device_bound_sources[@]}"
done

for test in \
  tests/CoordinatedPlistReadTests.swift \
  tests/SharedImportWorkerTests.swift \
  tests/SharedInboxCleanupTests.swift \
  tests/SharedInboxContainmentTests.swift \
  tests/SharedMetadataNameTests.swift; do
  run_swift_test "$test" "${inbox_sources[@]}"
done

for test in tests/SharedImportQueueTests.swift tests/SharedInboxIsolationTests.swift; do
  run_swift_test "$test" "${inbox_sources[@]}" GestaltX/SharedImportQueue.swift
done

run_swift_test tests/DirectFileImportTests.swift \
  "${inbox_sources[@]}" GestaltX/SharedImportQueue.swift GestaltX/DirectFileImports.swift
run_swift_test tests/DevicePlistIdentityTests.swift \
  "${inbox_sources[@]}" GestaltX/DevicePlistIdentity.swift
run_swift_test tests/SharedImportRecoveryTests.swift \
  "${device_bound_sources[@]}" GestaltX/DevicePlistIdentity.swift
run_swift_test tests/ItemProviderLoadTests.swift ShareExtension/ItemProviderLoad.swift
run_swift_test tests/TemporaryExportTests.swift GestaltX/TemporaryExport.swift

expected="$build_dir/expected-swift-tests.txt"
actual="$build_dir/actual-swift-tests.txt"
{
  for test in tests/*Tests.swift; do
    [[ -f "$test" ]] && printf '%s\n' "$test"
  done
} | LC_ALL=C sort > "$expected"
LC_ALL=C sort -u "$manifest" > "$actual"
if ! cmp -s "$expected" "$actual"; then
  echo "Error: Swift test manifest is incomplete" >&2
  diff -u "$expected" "$actual" >&2 || true
  exit 1
fi

expected_native="$build_dir/expected-native-tests.txt"
actual_native="$build_dir/actual-native-tests.txt"
{
  for test in tests/*Tests.m tests/*Tests.mm; do
    [[ -f "$test" ]] && printf '%s\n' "$test"
  done
} | LC_ALL=C sort > "$expected_native"
printf '%s\n' tests/CacheDirectoryTests.m > "$actual_native"
if ! cmp -s "$expected_native" "$actual_native"; then
  echo "Error: native test manifest is incomplete" >&2
  diff -u "$expected_native" "$actual_native" >&2 || true
  exit 1
fi

echo "==> CacheDirectoryTests"
xcrun --sdk macosx clang -fobjc-arc -fblocks -fmodules -Wall -Wextra \
  -DGESTALTX_TESTING=1 -I GestaltX \
  GestaltX/GXCacheDirectory.m tests/CacheDirectoryTests.m \
  -framework Foundation -o "$build_dir/CacheDirectoryTests"
run_with_timeout "$build_dir/CacheDirectoryTests"

expected_python="$build_dir/expected-python-tests.txt"
actual_python="$build_dir/actual-python-tests.txt"
{
  for test in tests/*Tests.py; do
    [[ -f "$test" ]] && printf '%s\n' "$test"
  done
} | LC_ALL=C sort > "$expected_python"
python_tests=(tests/LocalizationTests.py)
printf '%s\n' "${python_tests[@]}" | LC_ALL=C sort -u > "$actual_python"
if ! cmp -s "$expected_python" "$actual_python"; then
  echo "Error: Python test manifest is incomplete" >&2
  diff -u "$expected_python" "$actual_python" >&2 || true
  exit 1
fi
for test in "${python_tests[@]}"; do
  echo "==> ${test##*/}"
  python3 "$test"
done
echo "PASS: every declared hardening test compiled and ran."
