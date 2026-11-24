"""Minimal App Store Connect API client, shared by the release scripts.

No third-party HTTP or JWT dependency on purpose: stdlib plus `cryptography`,
which stock macOS python3 has. Credentials come from Config/AppStoreConnect.env
(ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH), which is git-ignored.
"""
import base64, json, os, pathlib, sys, time, urllib.error, urllib.request

APP_ID = os.environ.get("ASC_APP_ID", "6824085422")  # "LightEditor RAW"
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
    """(status, parsed JSON). Errors come back as a status too, for 409 and the like."""
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


def wait_for_build(version: str, platform: str = "", timeout=45 * 60) -> str:
    """The build's ID once App Store Connect finishes processing it.

    `platform` ("IOS" or "MAC_OS") matters when both platforms have a build with
    this number, since build numbers are timestamps.
    """
    deadline = time.time() + timeout
    where = f"&filter[preReleaseVersion.platform]={platform}" if platform else ""
    while True:
        status, body = call("GET", f"/v1/builds?filter[app]={APP_ID}&filter[version]={version}{where}&fields[builds]=processingState")
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
