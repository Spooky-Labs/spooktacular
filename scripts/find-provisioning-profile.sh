#!/bin/bash
# Finds the newest provisioning profile whose application-identifier
# (minus the team-id prefix) matches the given bundle ID.
#
# Usage:
#   ./scripts/find-provisioning-profile.sh com.spooktacular.app
#   ./scripts/find-provisioning-profile.sh com.spooktacular.app.NetworkFilter
#
# Stdout: absolute path to the matching .mobileprovision /
# .provisionprofile (newest mtime). Exit non-zero if none match.
#
# Looks in both profile directories Xcode / fastlane-match use:
#   ~/Library/MobileDevice/Provisioning Profiles/
#   ~/Library/Developer/Xcode/UserData/Provisioning Profiles/
#
# The script is a pure lookup — it never installs a profile. Run
# `bundle exec fastlane signing_dev` first if the search turns up
# empty.

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "usage: $0 <bundle-id>" >&2
    exit 2
fi

BUNDLE_ID="$1"
DIRS=(
    "$HOME/Library/MobileDevice/Provisioning Profiles"
    "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
)

best=""
best_mtime=0

for dir in "${DIRS[@]}"; do
    [ -d "$dir" ] || continue
    while IFS= read -r -d '' profile; do
        # `security cms -D -i file` unwraps the CMS signature and
        # prints the inner plist to stdout. PlistBuddy then reads
        # it directly — no temp file needed.
        plist="$(security cms -D -i "$profile" 2>/dev/null || echo "")"
        [ -n "$plist" ] || continue
        appid="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:application-identifier" /dev/stdin <<<"$plist" 2>/dev/null || true)"
        [ -n "$appid" ] || continue
        # application-identifier is `<TEAM_ID>.<bundle-id>`. Match
        # by stripping the team-id prefix.
        suffix="${appid#*.}"
        if [ "$suffix" = "$BUNDLE_ID" ]; then
            mtime="$(stat -f %m "$profile")"
            if [ "$mtime" -gt "$best_mtime" ]; then
                best="$profile"
                best_mtime="$mtime"
            fi
        fi
    done < <(find "$dir" \( -name "*.mobileprovision" -o -name "*.provisionprofile" \) -print0)
done

if [ -z "$best" ]; then
    exit 1
fi

echo "$best"
