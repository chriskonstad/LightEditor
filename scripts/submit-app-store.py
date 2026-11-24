#!/usr/bin/env python3
"""Submits an uploaded build to App Store review.

    scripts/submit-app-store.py ios 2611221339           version from project.yml
    scripts/submit-app-store.py macos 2611232015 1.0.5

Creates the App Store version for that platform if it doesn't exist yet, sets its
"What's New" from docs/app-store/listing.md (the same text scripts/tag-release.sh
puts in the GitHub release), attaches the build, and submits it for review. The
version releases automatically once Apple approves it.

Run it after scripts/testflight.sh has uploaded the build; it waits for App Store
Connect to finish processing. Safe to re-run: it reuses a version that is still
editable and never resubmits one that is already in review or on sale.

Authenticates with the App Store Connect API key from Config/AppStoreConnect.env
(ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH). Needs python3 with `cryptography`.
"""
import pathlib, re, sys

from asc import APP_ID, call, check, load_env, wait_for_build

PLATFORMS = {"ios": "IOS", "macos": "MAC_OS", "mac": "MAC_OS"}
ROOT = pathlib.Path(__file__).resolve().parent.parent
# States a version can still be edited and submitted in.
EDITABLE = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED",
            "INVALID_BINARY", "DEVELOPER_REMOVED_FROM_SALE"}


def project_version() -> str:
    """MARKETING_VERSION from project.yml, the one source for the app's version."""
    text = (ROOT / "project.yml").read_text()
    match = re.search(r'^ *MARKETING_VERSION: *"(.*)"', text, re.M)
    return match.group(1) if match else sys.exit("No MARKETING_VERSION in project.yml")


def release_notes(version: str) -> str:
    """The fenced block under "## What's New (<version>)" in the listing."""
    heading = "## What's New (first release)" if version == "1.0" else f"## What's New ({version})"
    text = (ROOT / "docs/app-store/listing.md").read_text()
    if heading not in text:
        sys.exit(f'No "{heading}" in docs/app-store/listing.md')
    after = text.split(heading, 1)[1]
    blocks = after.split("```")
    if len(blocks) < 2:
        sys.exit(f'No fenced notes under "{heading}" in docs/app-store/listing.md')
    return blocks[1].strip()


def find_version(version: str, platform: str):
    status, body = call("GET", f"/v1/apps/{APP_ID}/appStoreVersions?filter[versionString]={version}"
                               f"&filter[platform]={platform}&fields[appStoreVersions]=versionString,appStoreState")
    found = check(status, body, "Looking for the version").get("data", [])
    return found[0] if found else None


def create_version(version: str, platform: str):
    status, body = call("POST", "/v1/appStoreVersions", {"data": {
        "type": "appStoreVersions",
        "attributes": {"platform": platform, "versionString": version, "releaseType": "AFTER_APPROVAL"},
        "relationships": {"app": {"data": {"type": "apps", "id": APP_ID}}}}})
    return check(status, body, f"Creating version {version}")["data"]


def set_release_notes(version_id: str, notes: str):
    status, body = call("GET", f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations"
                               f"?fields[appStoreVersionLocalizations]=locale")
    existing = [l for l in check(status, body, "Reading the listing").get("data", [])
                if l["attributes"]["locale"] == "en-US"]
    if existing:
        check(*call("PATCH", f"/v1/appStoreVersionLocalizations/{existing[0]['id']}", {"data": {
            "type": "appStoreVersionLocalizations", "id": existing[0]["id"],
            "attributes": {"whatsNew": notes}}}), "Setting the release notes")
    else:
        check(*call("POST", "/v1/appStoreVersionLocalizations", {"data": {
            "type": "appStoreVersionLocalizations",
            "attributes": {"locale": "en-US", "whatsNew": notes},
            "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}}}}}),
              "Adding the release notes")


def attach_build(version_id: str, build_id: str):
    check(*call("PATCH", f"/v1/appStoreVersions/{version_id}/relationships/build",
                {"data": {"type": "builds", "id": build_id}}), "Attaching the build")


def submit(version_id: str, platform: str):
    """Puts the version in a review submission and submits it."""
    status, body = call("GET", f"/v1/reviewSubmissions?filter[app]={APP_ID}&filter[platform]={platform}"
                               f"&filter[state]=READY_FOR_REVIEW,UNRESOLVED_ISSUES&fields[reviewSubmissions]=state")
    open_submissions = check(status, body, "Looking for an open submission").get("data", [])
    if open_submissions:
        submission = open_submissions[0]
    else:
        status, body = call("POST", "/v1/reviewSubmissions", {"data": {
            "type": "reviewSubmissions", "attributes": {"platform": platform},
            "relationships": {"app": {"data": {"type": "apps", "id": APP_ID}}}}})
        submission = check(status, body, "Creating the review submission")["data"]

    status, body = call("POST", "/v1/reviewSubmissionItems", {"data": {
        "type": "reviewSubmissionItems",
        "relationships": {
            "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": submission["id"]}},
            "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}}}}})
    if status == 409:
        print("The version is already in this review submission.")
    else:
        check(status, body, "Adding the version to the submission")

    status, body = call("PATCH", f"/v1/reviewSubmissions/{submission['id']}", {"data": {
        "type": "reviewSubmissions", "id": submission["id"], "attributes": {"submitted": True}}})
    return check(status, body, "Submitting for review")["data"]["attributes"]["state"]


def main():
    if len(sys.argv) < 3 or sys.argv[1].lower() not in PLATFORMS:
        sys.exit(__doc__)
    load_env()
    platform = PLATFORMS[sys.argv[1].lower()]
    build = sys.argv[2]
    version = sys.argv[3] if len(sys.argv) > 3 else project_version()
    notes = release_notes(version)

    build_id = wait_for_build(build, platform)
    existing = find_version(version, platform)
    if existing:
        state = existing["attributes"]["appStoreState"]
        if state not in EDITABLE:
            sys.exit(f"{version} for {platform} is {state}; nothing to submit.")
        print(f"Reusing the {version} version for {platform} ({state}).")
        version_id = existing["id"]
    else:
        version_id = create_version(version, platform)["id"]
        print(f"Created {version} for {platform}.")

    set_release_notes(version_id, notes)
    attach_build(version_id, build_id)
    state = submit(version_id, platform)
    print(f"Submitted {version} ({platform}) with build {build} for review: {state}.")
    print("It releases automatically once Apple approves it.")


if __name__ == "__main__":
    main()
