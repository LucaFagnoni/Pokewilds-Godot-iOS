"""Prints the compat id of a project folder: SHA-256 over every file that the
shared game depends on, that is everything under project/ except the
client-only paths of tools/client_only_paths.txt (and Godot's .godot cache).
Builds with the same id play together (coop_session.gd refusal); CI writes it
to project/compat_id.txt next to build_id.txt.

    python tools/compat_id.py [PROJECT_DIR]        (default: project)

The same files give the same id on every OS: paths are sorted, "/"-separated
and NFC, and CRLF is read as LF. Standard library only."""
import fnmatch, hashlib, os, sys, unicodedata

LIST = os.path.join(os.path.dirname(os.path.abspath(__file__)), "client_only_paths.txt")


def client_only(path=LIST):
    """The globs of the list file, comments and blank lines dropped."""
    return [line.split("#", 1)[0].strip() for line in open(path, encoding="utf-8") if line.split("#", 1)[0].strip()]


def shared_files(project, globs):
    """Project-relative paths of the files the id covers, sorted."""
    found = []
    for folder, dirs, files in os.walk(project):
        dirs[:] = [d for d in dirs if d != ".godot"]  # the import cache, made from the files hashed here
        for name in files:
            rel = unicodedata.normalize("NFC", os.path.relpath(os.path.join(folder, name), project).replace(os.sep, "/"))
            if not any(fnmatch.fnmatchcase(rel, g) for g in globs):
                found.append(rel)
    return sorted(found)


def compat_id(project, globs=None):
    globs = client_only() if globs is None else globs
    total = hashlib.sha256()
    for rel in shared_files(project, globs):
        with open(os.path.join(project, rel), "rb") as f:
            data = f.read().replace(b"\r\n", b"\n")
        total.update(rel.encode() + b"\0" + hashlib.sha256(data).digest())
    return total.hexdigest()


if __name__ == "__main__":
    print(compat_id(sys.argv[1] if len(sys.argv) > 1 else "project"))
