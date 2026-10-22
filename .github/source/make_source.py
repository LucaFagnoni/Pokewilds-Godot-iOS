"""The PokeWilds source for Feather, AltStore, SideStore and other sideloading
apps (AltStore's source format): every published release's IPA, newest first.

    gh api "repos/LucaFagnoni/Pokewilds-Godot-iOS/releases?per_page=100" | python3 make_source.py > apps.json

The publish job of .github/workflows/build.yml runs it after each release and
stores apps.json on the "source" branch, the address the README gives.
"""
import json, re, sys

REPO = "LucaFagnoni/Pokewilds-Godot-iOS"
ICON = f"https://raw.githubusercontent.com/{REPO}/main/project/assets/icon.png"
ABOUT = "An iPhone port of PokeWilds, remade in Godot, with a Windows dedicated server for co-op."

versions = []
for release in json.load(sys.stdin):
    body = release["body"] or ""
    ipa = next((a for a in release["assets"] if a["name"] == "Pokewilds-unsigned.ipa"), None)
    # The draft job writes "IPA version 0.10.175 (175)" in every release's notes.
    found = re.search(r"IPA version (\S+) \((\d+)\)", body)
    if release["draft"] or release["prerelease"] or not ipa or not found:
        continue
    # The notes start with the commit message; drop its Co-Authored-By trailer.
    message = body.split("IPA version")[0].strip()
    versions.append({
        "version": found[1],
        "buildVersion": found[2],
        "date": release["published_at"],
        "localizedDescription": "\n".join(l for l in message.splitlines() if not l.startswith("Co-Authored-By")).strip(),
        "downloadURL": ipa["browser_download_url"],
        "size": ipa["size"],
        "minOSVersion": "15.0",
    })
versions.sort(key=lambda v: v["date"], reverse=True)
# Two releases of one commit (a rebuild) share a version: keep the newest.
seen = set()
versions = [v for v in versions if not (v["version"] in seen or seen.add(v["version"]))]
latest = versions[0]

app = {
    "name": "PokeWilds",
    "bundleIdentifier": "com.bebo.pokewilds",
    "developerName": "LucaFagnoni",
    "subtitle": "Explore, catch and build in a wild open world.",
    "localizedDescription": ABOUT,
    "iconURL": ICON,
    "tintColor": "#3E8E41",
    "category": "games",
    "screenshots": [],
    "versions": versions,
    # The IPA is unsigned (no entitlements); Godot's export leaves these three
    # usage descriptions empty in Info.plist, and AltStore wants them listed.
    "appPermissions": {
        "entitlements": [],
        "privacy": {
            "NSCameraUsageDescription": "Not used by the game (Godot's default key).",
            "NSMicrophoneUsageDescription": "Not used by the game (Godot's default key).",
            "NSPhotoLibraryUsageDescription": "Not used by the game (Godot's default key).",
        },
    },
    # The newest version again, for apps that only read these older fields.
    "version": latest["version"],
    "versionDate": latest["date"],
    "versionDescription": latest["localizedDescription"],
    "downloadURL": latest["downloadURL"],
    "size": latest["size"],
}
source = {
    "name": "PokeWilds",
    "identifier": "com.bebo.pokewilds.source",
    "subtitle": "PokeWilds for iPhone",
    "description": ABOUT,
    "iconURL": ICON,
    "website": f"https://github.com/{REPO}",
    "tintColor": "#3E8E41",
    "apps": [app],
    "news": [],
}
json.dump(source, sys.stdout, indent=2, ensure_ascii=False)
print()
