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
import base64, json, os, pathlib, sys, time, urllib.error, urllib.request

APP_ID = os.environ.get("ASC_APP_ID", "6824085422")  # "LightEditor RAW"
GROUP = os.environ.get("ASC_EXTERNAL_GROUP", "Friends")
BASE = "https://api.appstoreconnect.apple.com"


def load_env():
    """Reads Config/AppStoreConnect.env (shell KEY=value lines) into os.environ."""
    path = pathlib.Path(__file__).resolve().parent.parent / "Config/AppStoreConnect.env"
    if not path.exists():
        return
    for line in path.read_text().splitlines():
        line = line.strip().removeprefix("export ")
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            os.environ.setdefault(key.strip(), os.path.expanduser(os.path.expandvars(value.strip().strip('"').strip("'"))))


def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def token() -> str:
    """An ES256 JWT for the App Store Connect API, valid for 15 minutes."""
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec, utils

    key_id, issuer = os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"]
    key_path = os.environ.get("ASC_KEY_PATH") or str(pathlib.Path.home() / f".appstoreconnect/private_keys/AuthKey_{key_id}.p8")
    key = serialization.load_pem_private_key(pathlib.Path(key_path).read_bytes(), password=None)
    now = int(time.time())
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    payload = {"iss": issuer, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}
    signing_input = f"{b64(json.dumps(header).encode())}.{b64(json.dumps(payload).encode())}"
    r, s = utils.decode_dss_signature(key.sign(signing_input.encode(), ec.ECDSA(hashes.SHA256())))
    return f"{signing_input}.{b64(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))}"


def call(method: str, path: str, body=None):
    request = urllib.request.Request(BASE + path, method=method)
    request.add_header("Authorization", "Bearer " + token())
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, data, timeout=60) as response:
            raw = response.read()
            return response.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as error:
        raw = error.read()
        try:
            return error.code, json.loads(raw)
        except ValueError:
            return error.code, {"raw": raw.decode(errors="replace")}


def check(status, body, what):
    if status >= 300:
        sys.exit(f"{what} failed ({status}): {json.dumps(body.get('errors', body))}")
    return body


def wait_for_build(version: str, timeout=45 * 60):
    """The build's ID once processing finishes."""
    deadline = time.time() + timeout
    while True:
        status, body = call("GET", f"/v1/builds?filter[app]={APP_ID}&filter[version]={version}&fields[builds]=processingState")
        builds = check(status, body, "Looking up the build").get("data", [])
        state = builds[0]["attributes"]["processingState"] if builds else "NOT_YET_LISTED"
        if state == "VALID":
            return builds[0]["id"]
        if state in ("FAILED", "INVALID"):
            sys.exit(f"Build {version} failed processing ({state})")
        if time.time() > deadline:
            sys.exit(f"Build {version} is still {state} after {timeout // 60} minutes; run this script again later")
        print(f"Build {version}: {state}, waiting…", flush=True)
        time.sleep(30)


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
