POKEWILDS v0.9.3 â€” SOURCE AND BUILD MATERIALS
Snapshot: fixes170, 2026-10-09

CODE LICENSE: GPL-3.0-only for this port's original code contributions. See LICENSE and LICENSE-SCOPE.txt. Existing
third-party license notices are preserved. Art/audio/data are separately covered;
this is not a claim that every bundled resource is GPL or fully open licensed.

CONTENTS
project/: current Godot scripts, scene, assets, data, import settings, credits,
export preset and locally available Android wrapper source.
BUILD.txt: desktop and Android instructions and required external dependencies.
CONTRIBUTING.txt: working on forks and submitting changes.
LICENSE-SCOPE.txt / LICENSE-STATUS.txt: license scope and unresolved asset rights.
RIGHTS-REGISTER.csv: component-level provenance and remaining review.
FILE-MANIFEST.json and verify_files.py: package integrity verification.

MULTIPLAYER CHANGES
This copy adds embedded ZeroTier multiplayer and related fixes on top of the
fixes170 snapshot. The scripts, the Android wrapper and BUILD.txt differ from
that snapshot; FILE-MANIFEST.json was regenerated for this copy. lobby-directory/
holds the lobby list service. The change list is in the changelog.txt published
beside this package.

QUICK START
Install the matching Godot Standard engine, open project/project.godot, wait for
imports, and press F5. Read BUILD.txt before attempting an Android export.
Use Python 3 verify_files.py from this folder to verify delivered files.

SOURCE STATUS
Gameplay source is identical to the current fixes170 working source. Android
wrapper source was recovered from the existing .108/.117 wrapper workspace;
later APK builds reuse compiled native files. A fresh Android rebuild from this
package has not been verified against the shipped wrapper. Exact reproducibility
is not claimed. Build tools and engine binaries are not bundled.

Excluded: saves, personal settings, signing keys, credentials, APKs, generated
imports, local caches and historical test dumps. No game files were changed and
nothing was uploaded or made public by this packaging task.

CREDITS
NoNoseYaKnow â€” ball mechanics.
Divinakra â€” Gen 2 Mega artwork; see the retained artwork credits.
Additional authors, original sources and notices remain beside their resources
and in project/ADDITIONAL-SPRITE-CREDITS.md and project/FRAME-CREDITS.md.
