#!/usr/bin/env python3
"""Build cairn's release artifact into --out: cairn.bundle (kli-dir-bundle-v1
envelope over {cairn.asd, version.sexp, src/**}) and pin (its git write-tree id,
the install integrity floor). Sorted entries/keys make the bytes a pure function
of the source; the bundle is parsed back to confirm it round-trips to the pin."""
import argparse
import base64
import json
import os
import subprocess
import tempfile


def read_bytes(path):
    with open(path, "rb") as f:
        return f.read()


def collect(asd, version, src):
    files = {"cairn.asd": read_bytes(asd), "version.sexp": read_bytes(version)}
    for dirpath, _dirs, names in os.walk(src):
        for name in names:
            path = os.path.join(dirpath, name)
            rel = "src/" + os.path.relpath(path, src).replace(os.sep, "/")
            files[rel] = read_bytes(path)
    return files


def bundle_bytes(files):
    obj = {"format": "kli-dir-bundle-v1",
           "files": {rel: base64.b64encode(files[rel]).decode("ascii")
                     for rel in sorted(files)}}
    return json.dumps(obj, sort_keys=True, separators=(",", ":")).encode("utf-8")


def parse_bundle(data):
    obj = json.loads(data)
    if obj.get("format") != "kli-dir-bundle-v1":
        raise SystemExit(f"unexpected envelope format: {obj.get('format')!r}")
    return {rel: base64.b64decode(b64) for rel, b64 in obj["files"].items()}


def git_tree_sha(files):
    env = dict(os.environ, GIT_CONFIG_NOSYSTEM="1",
               GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_SYSTEM="/dev/null")
    with tempfile.TemporaryDirectory() as d:
        env["HOME"] = d
        for rel, data in files.items():
            path = os.path.join(d, *rel.split("/"))
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "wb") as f:
                f.write(data)

        def git(*a):
            r = subprocess.run(["git", "-c", "core.autocrlf=false", *a], cwd=d,
                               env=env, capture_output=True, text=True)
            if r.returncode:
                raise RuntimeError(f"git {a} failed: {r.stderr}")
            return r.stdout
        git("init", "-q")
        git("add", "-A")
        return git("write-tree").strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--asd", required=True)
    ap.add_argument("--version", required=True)
    ap.add_argument("--src", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    files = collect(args.asd, args.version, args.src)
    envelope = bundle_bytes(files)
    pin = git_tree_sha(files)

    if git_tree_sha(parse_bundle(envelope)) != pin:
        raise SystemExit("bundle does not round-trip to its pin")

    with open(os.path.join(args.out, "cairn.bundle"), "wb") as f:
        f.write(envelope)
    with open(os.path.join(args.out, "pin"), "w") as f:
        f.write(pin + "\n")


if __name__ == "__main__":
    main()
