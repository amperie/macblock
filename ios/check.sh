#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TASK_BUILD=$(mktemp -d /tmp/orbit-phone-check.XXXXXX)
trap 'rm -rf "$TASK_BUILD"' EXIT
swiftc -module-cache-path "$TASK_BUILD/modules" ios/Shared/PhonePolicy.swift ios/Tests/PolicyTests.swift -o "$TASK_BUILD/policy-tests"
"$TASK_BUILD/policy-tests"
swiftc -module-cache-path "$TASK_BUILD/modules" ios/Shared/PhonePolicy.swift ios/OrbitApp/PhoneAPI.swift ios/Tests/APITests.swift -o "$TASK_BUILD/api-tests"
"$TASK_BUILD/api-tests"
PYTHONPYCACHEPREFIX="$TASK_BUILD/python-cache" python3 -m unittest discover -s tests -p 'test_ios_server.py' -v
xcodebuild -project ios/Orbit.xcodeproj -scheme Orbit -configuration Debug -sdk iphoneos \
  -derivedDataPath "$TASK_BUILD/derived" CODE_SIGNING_ALLOWED=NO build
