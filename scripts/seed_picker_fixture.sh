#!/usr/bin/env bash
set -euo pipefail
udid="$1"
app_source="$2"
work=$(mktemp -d "${RUNNER_TEMP:-/tmp}/amorechat-picker-fixtures.XXXXXX")
trap 'rm -r "$work"' EXIT
fixture="$work/PickerFixtures.app"
ditto "$app_source" "$fixture"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier app.amorechat.pickerfixtures' "$fixture/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Picker Fixtures' "$fixture/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :UIFileSharingEnabled true' "$fixture/Info.plist" || /usr/libexec/PlistBuddy -c 'Add :UIFileSharingEnabled bool true' "$fixture/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :LSSupportsOpeningDocumentsInPlace true' "$fixture/Info.plist" || /usr/libexec/PlistBuddy -c 'Add :LSSupportsOpeningDocumentsInPlace bool true' "$fixture/Info.plist"
mkdir -p "$work/Documents"
printf 'Synthetic fixture for Files document-picker testing.\n' > "$work/Documents/Amore-Picker-Note.txt"
python3 - "$work/Documents/Amore-Picker-History.zip" <<'PY'
import json, sys, zipfile
stamp = '2026-11-12T00:00:00.000Z'
with zipfile.ZipFile(sys.argv[1], 'w', zipfile.ZIP_DEFLATED) as archive:
    archive.writestr('manifest.json', json.dumps({'export_format_version': 3}))
    archive.writestr('chat_session_index.json', json.dumps([
        {'id': 'sample', 'inserted_at': stamp, 'updated_at': stamp}
    ]))
    archive.writestr('chat_sessions/sample.json', json.dumps({
        'id': 'sample', 'title': 'Fixture', 'inserted_at': stamp, 'messages': [{
            'id': 0, 'parent_id': None, 'role': 'USER', 'status': 'FINISHED', 'inserted_at': stamp,
            'fragments': [{'type': 'REQUEST', 'content': 'Hello from ZIP64-free DEFLATE'}]
        }]
    }))
PY
xcrun simctl install "$udid" "$fixture"
fixture_id=app.amorechat.pickerfixtures
container=$(xcrun simctl get_app_container "$udid" "$fixture_id" data)
mkdir -p "$container/Documents"
cp "$work/Documents/Amore-Picker-Note.txt" "$container/Documents/"
cp "$work/Documents/Amore-Picker-History.zip" "$container/Documents/"
xcrun simctl launch "$udid" "$fixture_id" >/dev/null
xcrun simctl terminate "$udid" "$fixture_id" || true
