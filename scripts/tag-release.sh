#!/bin/zsh
# Tags an App Store release on GitHub: an annotated tag v<version> and a GitHub
# release whose notes are that version's "What's New" from docs/app-store/listing.md.
# Run it when a version is submitted to the App Store, at the commit its builds
# were archived from.
#
#   scripts/tag-release.sh                         MARKETING_VERSION from project.yml, at HEAD
#   scripts/tag-release.sh 1.0.3 02457c1           a given version and commit
#   scripts/tag-release.sh 1.0.4 HEAD "iOS build 2611182104, Mac build 2611182107"
#                                                  ...with a line added to the notes
#
# Does nothing if the tag already exists. Needs the GitHub CLI (gh), signed in.
set -euo pipefail
cd "$(dirname "$0")/.."

version=${1:-$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml)}
commit=$(git rev-parse --verify "${2:-HEAD}^{commit}")
extra=${3:-}
tag="v$version"
remote=${RELEASE_REMOTE:-origin}
repo=$(git remote get-url "$remote" | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')

if git ls-remote --exit-code --tags "$remote" "refs/tags/$tag" >/dev/null 2>&1; then
    echo "$tag is already on $remote; nothing to do."
    exit 0
fi

# "What's New (1.0.4)", or "(first release)" for 1.0: the fenced block under it.
heading="## What's New ($version)"
[[ "$version" == "1.0" ]] && heading="## What's New (first release)"
notes=$(awk -v heading="$heading" '
    $0 == heading { found = 1; next }
    found && /^```/ { if (inside) exit; inside = 1; next }
    found && inside { print }
' docs/app-store/listing.md)
[[ -n "$notes" ]] || { echo "No \"$heading\" notes in docs/app-store/listing.md"; exit 1; }
[[ -n "$extra" ]] && notes="$notes"$'\n\n'"$extra"

# Only the highest version is "Latest", so tagging an older one never takes it over.
git fetch --quiet --tags "$remote"
highest=$( (git tag -l 'v*'; echo "$tag") | sort -V | tail -1)
latest=false
[[ "$highest" == "$tag" ]] && latest=true

git tag -a "$tag" "$commit" -m "LightEditor $version" -m "$notes"
git push "$remote" "refs/tags/$tag"
gh release create "$tag" --repo "$repo" --verify-tag --latest=$latest --title "LightEditor $version" --notes "$notes"
echo "Tagged $tag at $(git rev-parse --short "$commit") and created its GitHub release."
