#!/usr/bin/env python3
"""Replaces a version's App Store screenshots with the ones `just screenshots` made.

    scripts/upload-screenshots.py ios               version from project.yml
    scripts/upload-screenshots.py macos 1.0.6
    scripts/upload-screenshots.py ios --only iphone

Creates the App Store version if it doesn't exist yet (like scripts/submit-app-store.py,
which then reuses it), and for each device folder in build/screenshots/ that exists,
deletes that display type's screenshots and uploads the folder's PNGs in name order:

    iphone -> APP_IPHONE_67 (6.9")   ipad -> APP_IPAD_PRO_3GEN_129 (13")
    duo    -> APP_IPHONE_DUO         mac  -> APP_DESKTOP

A display type with no folder keeps its screenshots (a new version starts with the
previous version's). Run it before submitting: a version in review can't change them.
"""
import hashlib, pathlib, sys, time, urllib.request

from asc import call, check, load_env

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
submit = __import__("submit-app-store")

ROOT = pathlib.Path(__file__).resolve().parent.parent
FOLDERS = {
    "IOS": {"iphone": "APP_IPHONE_67", "ipad": "APP_IPAD_PRO_3GEN_129", "duo": "APP_IPHONE_DUO"},
    "MAC_OS": {"mac": "APP_DESKTOP"},
}


def localization(version_id: str) -> str:
    status, body = call("GET", f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations?fields[appStoreVersionLocalizations]=locale")
    found = [l for l in check(status, body, "Reading the listing").get("data", []) if l["attributes"]["locale"] == "en-US"]
    if found:
        return found[0]["id"]
    status, body = call("POST", "/v1/appStoreVersionLocalizations", {"data": {
        "type": "appStoreVersionLocalizations", "attributes": {"locale": "en-US"},
        "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}}}}})
    return check(status, body, "Adding the en-US listing")["data"]["id"]


def screenshot_set(localization_id: str, display_type: str) -> str:
    status, body = call("GET", f"/v1/appStoreVersionLocalizations/{localization_id}/appScreenshotSets"
                               f"?filter[screenshotDisplayType]={display_type}")
    found = check(status, body, "Reading the screenshot sets").get("data", [])
    if found:
        return found[0]["id"]
    status, body = call("POST", "/v1/appScreenshotSets", {"data": {
        "type": "appScreenshotSets", "attributes": {"screenshotDisplayType": display_type},
        "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": localization_id}}}}})
    return check(status, body, f"Creating the {display_type} set")["data"]["id"]


def upload(set_id: str, path: pathlib.Path) -> str:
    data = path.read_bytes()
    status, body = call("POST", "/v1/appScreenshots", {"data": {
        "type": "appScreenshots", "attributes": {"fileName": path.name, "fileSize": len(data)},
        "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}}}})
    shot = check(status, body, f"Reserving {path.name}")["data"]
    for operation in shot["attributes"]["uploadOperations"]:
        chunk = data[operation["offset"]:operation["offset"] + operation["length"]]
        request = urllib.request.Request(operation["url"], data=chunk, method=operation["method"])
        for header in operation.get("requestHeaders", []):
            request.add_header(header["name"], header["value"])
        with urllib.request.urlopen(request) as response:
            if response.status >= 300:
                sys.exit(f"Uploading {path.name} failed ({response.status})")
    check(*call("PATCH", f"/v1/appScreenshots/{shot['id']}", {"data": {
        "type": "appScreenshots", "id": shot["id"],
        "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}}), f"Committing {path.name}")
    return shot["id"]


def wait_until_processed(ids: list[str]):
    deadline = time.time() + 10 * 60
    pending = set(ids)
    while pending and time.time() < deadline:
        for shot_id in list(pending):
            status, body = call("GET", f"/v1/appScreenshots/{shot_id}?fields[appScreenshots]=fileName,assetDeliveryState")
            attributes = check(status, body, "Checking a screenshot")["data"]["attributes"]
            state = (attributes.get("assetDeliveryState") or {}).get("state")
            if state == "COMPLETE":
                pending.discard(shot_id)
            elif state == "FAILED":
                errors = attributes["assetDeliveryState"].get("errors")
                sys.exit(f"{attributes.get('fileName')} was rejected: {errors}")
        if pending:
            time.sleep(5)
    if pending:
        sys.exit(f"{len(pending)} screenshots are still processing; check App Store Connect")


def main():
    args = sys.argv[1:]
    if not args or args[0].lower() not in submit.PLATFORMS:
        sys.exit(__doc__)
    platform = submit.PLATFORMS[args[0].lower()]
    only = args[args.index("--only") + 1] if "--only" in args else None
    positional = [a for i, a in enumerate(args[1:], 1) if not a.startswith("--") and (i == 0 or args[i - 1] != "--only")]
    version = positional[0] if positional else submit.project_version()
    load_env()

    existing = submit.find_version(version, platform)
    if existing:
        state = existing["attributes"]["appStoreState"]
        if state not in submit.EDITABLE:
            sys.exit(f"{version} for {platform} is {state}; its screenshots can't change.")
        version_id = existing["id"]
    else:
        version_id = submit.create_version(version, platform)["id"]
        print(f"Created {version} for {platform}.")
    localization_id = localization(version_id)

    for folder, display_type in FOLDERS[platform].items():
        directory = ROOT / "build/screenshots" / folder
        files = sorted(directory.glob("*.png")) if directory.is_dir() else []
        if (only and folder != only) or not files:
            print(f"{display_type}: kept as is" + ("" if only else f" (no {directory.relative_to(ROOT)}/)"))
            continue
        set_id = screenshot_set(localization_id, display_type)
        status, body = call("GET", f"/v1/appScreenshotSets/{set_id}/appScreenshots?limit=50")
        for old in check(status, body, "Reading the current screenshots").get("data", []):
            check(*call("DELETE", f"/v1/appScreenshots/{old['id']}"), "Removing an old screenshot")
        ids = [upload(set_id, path) for path in files]
        wait_until_processed(ids)
        print(f"{display_type}: {len(ids)} screenshots from {directory.relative_to(ROOT)}/")


if __name__ == "__main__":
    main()
