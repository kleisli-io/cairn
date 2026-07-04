#!/usr/bin/env python3
# Clean-image witness: a kli binary that does not bundle cairn installs cairn's
# real source over a loopback origin, then a fresh `kli mcp-serve cairn` process
# loads the placed directory unit through ASDF in cairn.asd's declared order and
# serves its tools. cairn.asd is :serial with store before model, so serving at
# all proves the declared order was honored; creating a task, observing it, and
# searching it back exercises the store's FTS5 in the live libsqlite.
import argparse
import base64
import json
import os
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def read_bytes(path):
    with open(path, "rb") as f:
        return f.read()


def cairn_tree(asd, version, src):
    files = {"cairn.asd": read_bytes(asd), "version.sexp": read_bytes(version)}
    for dirpath, _dirs, names in os.walk(src):
        for name in names:
            path = os.path.join(dirpath, name)
            rel = "src/" + os.path.relpath(path, src).replace(os.sep, "/")
            files[rel] = read_bytes(path)
    return files


def bundle_bytes(files):
    obj = {"format": "kli-dir-bundle-v1",
           "files": {rel: base64.b64encode(data).decode("ascii")
                     for rel, data in files.items()}}
    return json.dumps(obj).encode("utf-8")


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


class Origin:
    def __init__(self, body):
        self.body = body
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), self._handler())
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def url(self):
        return f"http://127.0.0.1:{self.port}/cairn.bundle"

    def _handler(self):
        body = self.body

        class H(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *_a):
                pass

            def do_GET(self):
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
        return H

    def stop(self):
        self.httpd.shutdown()


class McpServer:
    def __init__(self, kli, ext_id, env, cwd):
        self.proc = subprocess.Popen(
            [kli, "mcp-serve", ext_id], cwd=cwd, env=env,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, bufsize=1)
        self._id = 0
        self._err = []
        threading.Thread(target=self._drain, daemon=True).start()

    def _drain(self):
        for line in self.proc.stderr:
            self._err.append(line)

    def stderr(self):
        return "".join(self._err)

    def _rpc(self, method, params=None):
        self._id += 1
        msg = {"jsonrpc": "2.0", "id": self._id, "method": method}
        if params is not None:
            msg["params"] = params
        self.proc.stdin.write(json.dumps(msg) + "\n")
        self.proc.stdin.flush()
        while True:
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError(f"server closed during {method} "
                                   f"(exit {self.proc.poll()})\n{self.stderr()}")
            m = json.loads(line)
            if m.get("id") == self._id:
                if "error" in m:
                    raise RuntimeError(f"jsonrpc error on {method}: {m['error']}")
                return m["result"]

    def initialize(self):
        self._rpc("initialize", {"protocolVersion": "2025-11-25",
                                 "capabilities": {},
                                 "clientInfo": {"name": "e2e", "version": "0"}})
        self.proc.stdin.write(
            '{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
        self.proc.stdin.flush()

    def tools(self):
        return [t["name"] for t in self._rpc("tools/list")["tools"]]

    def call(self, name, arguments):
        result = self._rpc("tools/call", {"name": name, "arguments": arguments})
        text = "\n".join(b.get("text", "") for b in result.get("content", []) or []
                         if isinstance(b, dict) and b.get("type") == "text")
        if result.get("isError"):
            raise RuntimeError(f"tool {name} isError: {text}")
        return text

    def close(self):
        try:
            self.proc.stdin.close()
        except OSError:
            pass
        try:
            self.proc.wait(timeout=60)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kli", required=True)
    ap.add_argument("--asd", required=True)
    ap.add_argument("--version", required=True)
    ap.add_argument("--src", required=True)
    args = ap.parse_args()

    files = cairn_tree(args.asd, args.version, args.src)
    origin = Origin(bundle_bytes(files))
    sha = git_tree_sha(files)

    with tempfile.TemporaryDirectory() as tmp:
        dirs = {k: os.path.join(tmp, k)
                for k in ("home", "config", "cache", "data", "state", "work")}
        for d in dirs.values():
            os.makedirs(d)
        env = dict(os.environ, HOME=dirs["home"], XDG_CONFIG_HOME=dirs["config"],
                   XDG_CACHE_HOME=dirs["cache"], XDG_DATA_HOME=dirs["data"],
                   XDG_STATE_HOME=dirs["state"])
        cwd = dirs["work"]
        try:
            r = subprocess.run([args.kli, "install", origin.url(), sha, "--yes"],
                               cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                               capture_output=True, text=True, timeout=600)
            if r.returncode != 0 or r.stdout.strip() != "cairn":
                raise AssertionError(
                    f"install: exit {r.returncode}, stdout {r.stdout!r}\n{r.stderr}")

            server = McpServer(args.kli, "cairn", env, cwd)
            try:
                server.initialize()
                names = server.tools()
                for want in ("task_create", "observe", "task_search"):
                    assert want in names, \
                        f"missing tool {want} in {names}\n{server.stderr()}"
                server.call("task_create", {"name": "e2e-witness"})
                server.call("observe", {"text": "cross-process witness marker zeta"})
                hit = server.call("task_search", {"query": "zeta"})
                assert "e2e-witness" in hit or "zeta" in hit, \
                    f"search missed the indexed observation: {hit!r}"
            finally:
                server.close()
        finally:
            origin.stop()
    print("ok: cairn installs, loads via ASDF in declared order, serves (FTS5 live)")


if __name__ == "__main__":
    main()
