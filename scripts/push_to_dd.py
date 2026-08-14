#!/usr/bin/env python3
"""Push the current branch to the DD build repo and follow the Actions run it starts.

Run it yourself:

    python3 scripts/push_to_dd.py            # commit nothing, push HEAD, watch the build
    python3 scripts/push_to_dd.py --no-watch # push and print the run URL, then exit
    python3 scripts/push_to_dd.py --dispatch # no push, just start a run on the pushed branch

The token is read from ~/.aorusgram/dd_token and never leaves this process: git receives it
through an askpass helper that reads the same file, so it is not in the command line, not in
.git/config, and not in anything this script prints.
"""

from __future__ import annotations

import argparse
import json
import os
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO_SLUG = "xdmitriymail-hub/DD"
REMOTE_URL = f"https://x-access-token@github.com/{REPO_SLUG}.git"
API = "https://api.github.com"
TOKEN_PATH = Path.home() / ".aorusgram" / "dd_token"
WORKFLOW_FILE = "build-aorusgram.yml"
ROOT = Path(__file__).resolve().parent.parent


def fail(message: str) -> "NoReturn":  # type: ignore[valid-type]
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def read_token() -> str:
    """Token from the file, with a look at its permissions on the way past."""
    if not TOKEN_PATH.is_file():
        fail(
            f"no token at {TOKEN_PATH}\n"
            f"       write it there and run: chmod 600 {TOKEN_PATH}"
        )
    mode = TOKEN_PATH.stat().st_mode
    if mode & (stat.S_IRWXG | stat.S_IRWXO):
        print(f"warning: {TOKEN_PATH} is readable by other users; chmod 600 it")
    token = TOKEN_PATH.read_text(encoding="utf-8").strip()
    if not token:
        fail(f"{TOKEN_PATH} is empty")
    return token


def git(*args: str, capture: bool = True, env: dict | None = None, isolated: bool = False) -> str:
    # isolated: talk to DD with the credential store switched off. Without this, git on macOS
    # hands whatever github.com login is in the keychain to the server and the private repo comes
    # back as "Repository not found" even though the token is fine.
    prefix = ["-c", "credential.helper="] if isolated else []
    result = subprocess.run(
        ["git", *prefix, *args],
        cwd=ROOT,
        text=True,
        capture_output=capture,
        env=env,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip() if capture else ""
        fail(f"git {' '.join(args)} failed\n{detail}")
    return (result.stdout or "").strip() if capture else ""


def api(token: str, path: str, method: str = "GET", body: dict | None = None) -> dict:
    """GitHub REST through curl rather than urllib.

    curl trusts the system keychain, which a python.org interpreter on macOS often does not --
    the same request from urllib fails with CERTIFICATE_VERIFY_FAILED on a stock install. The
    token goes in through a config file on stdin, so it stays out of the command line where
    `ps` would show it.
    """
    with tempfile.TemporaryDirectory(prefix="aorus-api-") as holder:
        out = Path(holder) / "out.json"
        config = [
            f'url = "{API}{path}"',
            f'request = "{method}"',
            f'header = "Authorization: Bearer {token}"',
            'header = "Accept: application/vnd.github+json"',
            'header = "X-GitHub-Api-Version: 2022-11-28"',
            'user-agent = "aorusgram-push"',
            f'output = "{out}"',
            "silent",
            "show-error",
            "fail-with-body",
            'write-out = "%{http_code}"',
        ]
        if body is not None:
            data = Path(holder) / "body.json"
            data.write_text(json.dumps(body), encoding="utf-8")
            config.append('header = "Content-Type: application/json"')
            config.append(f'data = "@{data}"')
        result = subprocess.run(
            ["curl", "--config", "-"],
            input="\n".join(config) + "\n",
            text=True,
            capture_output=True,
        )
        raw = out.read_text(encoding="utf-8") if out.is_file() else ""
        code = result.stdout.strip()[-3:]
        if not code.isdigit():
            fail(f"{method} {path} -> curl: {(result.stderr or 'no response').strip()[:300]}")
        if not 200 <= int(code) < 300:
            message = raw.strip()[:400] or result.stderr.strip()[:400]
            fail(f"{method} {path} -> HTTP {code} {message}")
        return json.loads(raw) if raw.strip() else {}


def check_clean(allow_dirty: bool) -> None:
    dirty = [
        line
        for line in git("status", "--porcelain").splitlines()
        # Untracked junk the build never reads is not worth blocking on.
        if line.strip() and not line.endswith(".DS_Store")
    ]
    if not dirty:
        return
    print("uncommitted changes:")
    for line in dirty:
        print(f"  {line}")
    if not allow_dirty:
        fail(
            "commit them first (a push sends commits, not your working copy), "
            "or re-run with --allow-dirty to push what is already committed"
        )
    print("--allow-dirty: pushing the committed state and leaving these behind")


def askpass_env(token_path: Path) -> tuple[dict, tempfile.TemporaryDirectory]:
    """An askpass helper that cats the token file, so the token is never in this env or argv."""
    holder = tempfile.TemporaryDirectory(prefix="aorus-askpass-")
    helper = Path(holder.name) / "askpass.sh"
    helper.write_text(f'#!/bin/sh\nexec cat "{token_path}"\n', encoding="utf-8")
    helper.chmod(0o700)
    env = dict(os.environ)
    env["GIT_ASKPASS"] = str(helper)
    env["GIT_TERMINAL_PROMPT"] = "0"
    return env, holder


def push(branch: str, force: bool) -> None:
    env, holder = askpass_env(TOKEN_PATH)
    try:
        remote_before = git(
            "ls-remote", REMOTE_URL, f"refs/heads/{branch}", env=env, isolated=True
        ).split("\t")[0]
        args = ["push", REMOTE_URL, f"HEAD:refs/heads/{branch}"]
        if force and remote_before:
            # Pinned to the sha just read rather than plain --force-with-lease, which needs a
            # remote-tracking ref this push does not have: DD is addressed by URL so that its
            # token never lands in .git/config.
            args.insert(1, f"--force-with-lease=refs/heads/{branch}:{remote_before}")
        print(f"pushing HEAD -> {REPO_SLUG} {branch}")
        subprocess.run(
            ["git", "-c", "credential.helper=", *args], cwd=ROOT, text=True, env=env, check=False
        )
        # Rather than trust the exit code of a command whose stderr we let through, confirm the
        # remote tip really is our commit.
        local = git("rev-parse", "HEAD")
        remote = git(
            "ls-remote", REMOTE_URL, f"refs/heads/{branch}", env=env, isolated=True
        ).split("\t")[0]
        if remote != local:
            fail(
                f"{branch} on {REPO_SLUG} is at {remote[:12] or 'nothing'}, not {local[:12]}\n"
                "       if DD has commits yours do not, re-run with --force"
            )
        print(f"pushed {local[:12]}")
    finally:
        holder.cleanup()


def latest_run(token: str, branch: str) -> dict | None:
    data = api(token, f"/repos/{REPO_SLUG}/actions/runs?branch={branch}&per_page=1")
    runs = data.get("workflow_runs") or []
    return runs[0] if runs else None


def wait_for_run(token: str, branch: str, after: str | None, timeout: float = 180.0) -> dict | None:
    """The push trigger takes a few seconds to show up; anything longer means it did not fire."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        run = latest_run(token, branch)
        if run and run.get("id") != after:
            return run
        time.sleep(5.0)
    return None


def watch(token: str, run: dict) -> int:
    run_id = run["id"]
    print(f"run {run_id}: {run['html_url']}")
    last = ""
    while True:
        run = api(token, f"/repos/{REPO_SLUG}/actions/runs/{run_id}")
        status = run.get("status") or "?"
        conclusion = run.get("conclusion")
        line = f"{status}{f' ({conclusion})' if conclusion else ''}"
        if line != last:
            print(f"  {time.strftime('%H:%M:%S')} {line}")
            last = line
        if status == "completed":
            if conclusion == "success":
                print(f"build succeeded -- artifacts: {run['html_url']}")
                return 0
            print(f"build {conclusion} -- logs: {run['html_url']}")
            return 1
        # A Bazel build runs 40-60 minutes; polling every half minute is plenty.
        time.sleep(30.0)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--branch", help="branch name on DD (default: the branch checked out here)")
    parser.add_argument("--force", action="store_true", help="overwrite the branch on DD (with lease)")
    parser.add_argument("--allow-dirty", action="store_true", help="push even with uncommitted changes")
    parser.add_argument("--no-watch", action="store_true", help="print the run URL and exit")
    parser.add_argument(
        "--dispatch",
        action="store_true",
        help="do not push; start a run on the branch already there (needs the workflow on DD's default branch)",
    )
    args = parser.parse_args()

    if not (ROOT / ".git").exists():
        fail(f"{ROOT} is not a git repository")
    branch = args.branch or git("rev-parse", "--abbrev-ref", "HEAD")
    if branch == "HEAD":
        fail("detached HEAD: pass --branch")
    if branch != "main" and not branch.startswith(("claude/", "cursor/")):
        print(
            f"warning: {WORKFLOW_FILE} only builds main, claude/** and cursor/**;\n"
            f"         {branch} will need --dispatch to start a run"
        )

    token = read_token()
    print(f"repo: {REPO_SLUG}   branch: {branch}")

    if args.dispatch:
        api(
            token,
            f"/repos/{REPO_SLUG}/actions/workflows/{WORKFLOW_FILE}/dispatches",
            method="POST",
            body={"ref": branch},
        )
        print("dispatched")
        before = None
    else:
        check_clean(args.allow_dirty)
        previous = latest_run(token, branch)
        before = previous.get("id") if previous else None
        push(branch, args.force)

    run = wait_for_run(token, branch, before)
    if run is None:
        fail(
            "no run appeared within 3 minutes\n"
            f"       check {'https://github.com/' + REPO_SLUG}/actions"
        )
    if args.no_watch:
        print(f"run {run['id']}: {run['html_url']}")
        return 0
    return watch(token, run)


if __name__ == "__main__":
    sys.exit(main())
