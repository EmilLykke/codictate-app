#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# Apple identity, resolved from the environment so neither `eas build` nor
# `eas submit` has to ask. Exported (not inlined) precisely so both get them.
#
#   EXPO_APPLE_ID          - skips the "Apple ID:" question.
#   EXPO_APPLE_PROVIDER_ID - skips "Select a Provider". This account can see
#     two: Joachim Strøjer Hansen (128315484) and Emil Lykke Grann
#     (128767488). Codictate ships under the same Apple team as Koffeelab
#     (L256GR2793), so the provider is the same one. eas-cli asserts the id is
#     reachable before switching to it, so a wrong or revoked id fails loudly
#     instead of silently shipping under the other provider.
export EXPO_APPLE_ID="emillykkeg@gmail.com"
export EXPO_APPLE_PROVIDER_ID="128767488"

PROFILE="${PROFILE:-production}"
IPA_PATH="build/codictate-$PROFILE.ipa"

# No .env here on purpose: Codictate transcribes on device and talks to no API,
# so there is nothing to inject. The vendored binaries a local build does need
# (crispasr xcframework, llama) are fetched by the `eas-build-post-install`
# script in package.json, which EAS runs for local builds too.

# EAS snapshots the repo when the build STARTS. Uncommitted work never makes it
# into the IPA, and commits made while the build runs don't either. Refuse a
# dirty tree up front, and refuse to submit if HEAD moved during the build.
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree is dirty. Commit first; uncommitted changes would NOT be in the IPA." >&2
  exit 1
fi
START_SHA="$(git rev-parse HEAD)"
echo "Building from $(git log --oneline -1 HEAD)"

# The marketing version (CFBundleShortVersionString) decides WHICH App Store
# Connect version page the build lands on. A build whose version still reads
# 1.0.1 cannot attach to the 1.0.2 page, and eas.json's autoIncrement only ever
# touches the build number, never this. Pass the version you created in ASC as
# $1 to assert it up front, before the build time is spent on the wrong one.
APP_VERSION="$(bunx expo config --type public --json |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')"
EXPECTED_VERSION="${1:-}"
if [[ -n "$EXPECTED_VERSION" && "$APP_VERSION" != "$EXPECTED_VERSION" ]]; then
  echo "app.config.ts version is $APP_VERSION, expected $EXPECTED_VERSION. Bump it before building." >&2
  exit 1
fi
echo "Marketing version $APP_VERSION. Must match the App Store Connect version page you intend to submit to."

mkdir -p build

# SKIP_BUILD=1 submits an IPA that is already on disk, for when the build
# succeeded but a later step failed. The version and HEAD checks below still
# run, so a stale artifact cannot slip through unnoticed.
SKIP_BUILD="${SKIP_BUILD:-}"
if [[ -n "$SKIP_BUILD" ]]; then
  if [[ ! -f "$IPA_PATH" ]]; then
    echo "SKIP_BUILD is set but $IPA_PATH does not exist. Run without SKIP_BUILD to build it." >&2
    exit 1
  fi
  echo "SKIP_BUILD set: submitting the existing $IPA_PATH without rebuilding."
else
  rm -f "$IPA_PATH"
fi

# One question is left that no environment variable can answer. eas-cli asks it
# with a plain confirm prompt and always gets the same reply, so expect sends it:
#   "Do you want to log in to your Apple account?" -> Enter (default Y)
# It lives in its own `interact` block so it fires exactly once; a looping
# pattern would re-trigger on prompt-line redraws.
#
# The keyboard stays passed through throughout, so a fresh 2FA challenge is
# still typable. The trailing `interact` covers the rest of the build and
# carries one watcher: if "Select a Provider" ever appears, EXPO_APPLE_PROVIDER_ID
# did not take. It only warns rather than answering, because guessing here can
# ship under the wrong provider and a long build is too expensive to lose to a
# hard exit. Pick the provider by hand, then fix the variable.
if [[ -z "$SKIP_BUILD" ]]; then
  expect -c '
    set timeout -1
    spawn bunx eas build --profile '"$PROFILE"' --platform ios --local --output '"$IPA_PATH"'
    catch {
      interact {
        -o -nobuffer "log in to your Apple account?" { send "\r"; return }
      }
      interact {
        -o -nobuffer "Select a Provider" {
          send_user "\n>>> EXPO_APPLE_PROVIDER_ID was ignored. Choose Emil Lykke Grann (128767488) by hand, then fix scripts/release-ios.sh.\n"
        }
      }
    }
    catch wait result
    exit [lindex $result 3]
  '
fi

if [[ "$(git rev-parse HEAD)" != "$START_SHA" ]]; then
  echo "HEAD moved during the build. The IPA snapshot is stale; re-run to rebuild from the new commit." >&2
  exit 1
fi

if [[ ! -f "$IPA_PATH" ]]; then
  echo "Build produced no IPA at $IPA_PATH. Build failed; nothing submitted." >&2
  exit 1
fi

# Info.plist inside an IPA is a BINARY plist. Piping it through $(...) strips
# the NUL bytes and plutil then rejects the result ("Unexpected character b"),
# so unzip it to a file and let plutil read the file.
IPA_PLIST="$(mktemp -t codictate-info-plist)"
trap 'rm -f "$IPA_PLIST"' EXIT
unzip -p "$IPA_PATH" "Payload/*.app/Info.plist" > "$IPA_PLIST"
BUILD_NUM="$(plutil -extract CFBundleVersion raw -o - "$IPA_PLIST")"
IPA_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$IPA_PLIST")"

# Read from the IPA rather than trusting the config: prebuild only regenerates
# ios/ when it runs, so a stale native project can ship a version string the
# config no longer has.
if [[ "$IPA_VERSION" != "$APP_VERSION" ]]; then
  echo "IPA says version $IPA_VERSION but app.config.ts says $APP_VERSION. Stale native project; run bun run prebuild:ios and rebuild." >&2
  exit 1
fi

echo "Submitting version $IPA_VERSION build $BUILD_NUM (commit $START_SHA)"
echo "This attaches to the App Store Connect page for version $IPA_VERSION. It must exist there and be editable."
echo "After TestFlight processing, verify the phone shows build $BUILD_NUM before testing."

bunx eas submit \
  --platform ios \
  --profile "$PROFILE" \
  --path "$IPA_PATH"
