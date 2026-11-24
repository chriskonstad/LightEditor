#!/usr/bin/env python3
"""Sends an uploaded TestFlight build to an external beta group.

    scripts/testflight-external.py <build number> ["What to Test" text]

Waits for App Store Connect to finish processing the build, sets its "What to
Test" notes, adds it to the external group ("Friends" unless ASC_EXTERNAL_GROUP
says otherwise) and submits it for Beta App Review. External testers get it once
Apple approves it, usually within a day for the first build of a version and
often automatically after that. scripts/testflight.sh runs this after uploading.

Authenticates with the App Store Connect API key from Config/AppStoreConnect.env
(ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH). Needs python3 with `cryptography`.
"""
import json, os, sys

from asc import APP_ID, call, check, load_env, wait_for_build

GROUP = os.environ.get("ASC_EXTERNAL_GROUP", "Friends")


def set_what_to_test(build_id: str, text: str):
    status, body = call("GET", f"/v1/builds/{build_id}/betaBuildLocalizations")
    existing = [l for l in check(status, body, "Reading notes").get("data", []) if l["attributes"]["locale"] == "en-US"]
    if existing:
        check(*call("PATCH", f"/v1/betaBuildLocalizations/{existing[0]['id']}", {"data": {
            "type": "betaBuildLocalizations", "id": existing[0]["id"], "attributes": {"whatsNew": text}}}), "Updating notes")
    else:
        check(*call("POST", "/v1/betaBuildLocalizations", {"data": {
            "type": "betaBuildLocalizations", "attributes": {"locale": "en-US", "whatsNew": text},
            "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}}), "Adding notes")


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    load_env()
    version = sys.argv[1]
    notes = sys.argv[2] if len(sys.argv) > 2 else ""

    status, body = call("GET", f"/v1/apps/{APP_ID}/betaGroups?fields[betaGroups]=name,isInternalGroup")
    groups = [g for g in check(status, body, "Listing groups")["data"]
              if g["attributes"]["name"] == GROUP and not g["attributes"]["isInternalGroup"]]
    if not groups:
        sys.exit(f'No external beta group named "{GROUP}"')

    build_id = wait_for_build(version)
    status, body = call("GET", f"/v1/builds/{build_id}/buildBetaDetail")
    if check(status, body, "Reading the build")["data"]["attributes"]["externalBuildState"] == "NOT_APPLICABLE":
        sys.exit(f"Build {version} was uploaded for internal testing only, so it can't go to external testers")
    if notes:
        set_what_to_test(build_id, notes)
    check(*call("POST", f"/v1/betaGroups/{groups[0]['id']}/relationships/builds",
                {"data": [{"type": "builds", "id": build_id}]}), f'Adding to "{GROUP}"')
    status, body = call("POST", "/v1/betaAppReviewSubmissions", {"data": {
        "type": "betaAppReviewSubmissions", "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}})
    if status == 409:
        print(f"Build {version} was already submitted for Beta App Review")
    else:
        check(status, body, "Submitting for Beta App Review")
    status, body = call("GET", f"/v1/builds/{build_id}/buildBetaDetail")
    state = check(status, body, "Reading the build")["data"]["attributes"]["externalBuildState"]
    if state == "IN_BETA_TESTING":
        print(f'Build {version} is available to "{GROUP}" now.')
    else:
        print(f'Build {version} is in "{GROUP}" ({state}); testers get it once Beta App Review approves it.')


if __name__ == "__main__":
    main()
