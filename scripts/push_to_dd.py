#!/usr/bin/env python3
"""Push the current branch to the build repo and follow the Actions run it starts.

Run it yourself, or let Claude run it:

    python3 scripts/push_to_dd.py            # push HEAD, watch the build
    python3 scripts/push_to_dd.py --no-watch # push and print the run URL, then exit
    python3 scripts/push_to_dd.py --dispatch # no push, just start a run on the pushed branch

The token is never read by this script. It is named by path and handed to git through an
askpass helper and to curl through a config assembled by /bin/sh, so its bytes exist only
inside those two programs -- not in Python memory, not in argv, not in .git/config, and not
in anything this script can print.
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

REPO_SLUG = "XxxSigmaBoyyy/BETA"
REMOTE_URL = f"https://x-access-token@github.com/{REPO_SLUG}.git"
API = "https://api.github.com"
WORKFLOW_FILE = "build-aorusgram.yml"
ROOT = Path(__file__).resolve().parent.parent
# In the working copy, ignored by .gitignore, and read only by git and curl.
TOKEN_PATH = ROOT / "dd.txt"


def fail(message: str) -> "NoReturn":  # type: ignore[valid-type]
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def check_token_file() -> None:
    """Look at the file without opening it: size and mode only."""
    if not TOKEN_PATH.is_file():
        fail(f"no token at {TOKEN_PATH}")
    info = TOKEN_PATH.stat()
    if info.st_size == 0:
        fail(f"{TOKEN_PATH} is empty")
    if info.st_mode & (stat.S_IRWXG | stat.S_IRWXO):
        print(f"warning: {TOKEN_PATH} is readable by other users; chmod 600 it")


def git(*args: str, capture: bool = True, env: dict | None = None, isolated: bool = False) -> str:
    # isolated: talk to the build repo with the credential store switched off. Without this, git
    # on macOS hands whatever github.com login is in the keychain to the server and a private repo
    # comes back as "Repository not found" even though the token is fine.
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


def api(path: str, method: str = "GET", body: dict | None = None) -> dict:
    """GitHub REST through curl, with the Authorization header assembled by /bin/sh.

    Two reasons it is shaped like this. curl trusts the system keychain, which a python.org
    interpreter on macOS often does not -- the same request from urllib fails with
    CERTIFICATE_VERIFY_FAILED. And `printf ... "$(cat token)" | curl --config -` keeps the token
    inside the shell and curl: it never reaches this process, and a config on stdin never reaches
    the command line where `ps` would show it.
    """
    with tempfile.TemporaryDirectory(prefix="aorus-api-") as holder:
        out = Path(holder) / "out.json"
        lines = [
            f'url = "{API}{path}"',
            f'request = "{method}"',
            "header = \"Authorization: Bearer %s\"",
            'header = "Accept: application/vnd.github+json"',
            'header = "X-GitHub-Api-Version: 2022-11-28"',
            'user-agent = "aorusgram-push"',
            f'output = "{out}"',
            "silent",
            "show-error",
            "fail-with-body",
            'write-out = "%%{http_code}"',
        ]
        if body is not None:
            data = Path(holder) / "body.json"
            data.write_text(json.dumps(body), encoding="utf-8")
            lines.append('header = "Content-Type: application/json"')
            lines.append(f'data = "@{data}"')
        # printf consumes exactly one %s -- the token -- and %%{http_code} above is curl's, escaped
        # so the shell's printf leaves it alone. $(cat) drops the file's trailing newline.
        script = "printf '" + "\\n".join(lines) + "\\n' \"$(cat \"$1\")\" | curl --config -"
        result = subprocess.run(
            ["/bin/sh", "-c", script, "sh", str(TOKEN_PATH)],
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
    # tr, not cat: a stray CR or trailing newline in the file would otherwise be sent as part of
    # the password and the server would answer 401.
    helper.write_text(f"#!/bin/sh\nexec tr -d '\\r\\n' < \"{token_path}\"\n", encoding="utf-8")
    helper.chmod(0o700)
    env = dict(os.environ)
    env["GIT_ASKPASS"] = str(helper)
    env["GIT_TERMINAL_PROMPT"] = "0"
    return env, holder


def remote_head(branch: str, env: dict) -> str:
    return git("ls-remote", REMOTE_URL, f"refs/heads/{branch}", env=env, isolated=True).split("\t")[0]


def push_once(refspec: str, env: dict, lease: str | None = None) -> bool:
    """One `git push` over HTTP/1.1, exit code reported rather than raised on.

    HTTP/2 is what fails on a first push of this repo: the whole history is one ~40 MiB pack and
    GitHub answers `HTTP 400 curl 22 / unexpected disconnect while reading sideband packet`
    partway through writing it. Forcing 1.1 and giving curl a post buffer big enough to hold the
    pack is the fix; slicing the history is the fallback when even that is too much for one
    request.
    """
    tuning = [
        "-c", "credential.helper=",
        "-c", "http.version=HTTP/1.1",
        "-c", "http.postBuffer=524288000",
        "-c", "http.lowSpeedLimit=0",
        "-c", "http.lowSpeedTime=600",
    ]
    args = ["push"]
    if lease is not None:
        args.append(f"--force-with-lease={lease}")
    args += [REMOTE_URL, refspec]
    result = subprocess.run(["git", *tuning, *args], cwd=ROOT, text=True, env=env, check=False)
    return result.returncode == 0


def push_in_slices(branch: str, env: dict) -> None:
    """Walk the history up in chunks, so each request carries a pack the server will accept."""
    commits = git("rev-list", "--reverse", "--first-parent", "HEAD").splitlines()
    if not commits:
        fail("no commits to push")
    step = max(1, len(commits) // 12)
    checkpoints = commits[step - 1 :: step]
    if checkpoints and checkpoints[-1] != commits[-1]:
        checkpoints.append(commits[-1])
    print(f"pushing {len(commits)} commits in {len(checkpoints)} slices")
    for index, sha in enumerate(checkpoints, start=1):
        print(f"  slice {index}/{len(checkpoints)} -> {sha[:12]}")
        for attempt in (1, 2, 3):
            if push_once(f"{sha}:refs/heads/{branch}", env):
                break
            if attempt == 3:
                fail(
                    f"slice {index} failed three times at {sha[:12]}\n"
                    "       the connection is dropping mid-pack; try again on a steadier network"
                )
            print(f"    retrying ({attempt}/2)")
            time.sleep(5.0)


def push(branch: str, force: bool) -> None:
    env, holder = askpass_env(TOKEN_PATH)
    try:
        remote_before = remote_head(branch, env)
        local = git("rev-parse", "HEAD")
        if remote_before == local:
            print(f"{branch} on {REPO_SLUG} is already at {local[:12]}")
            return
        # Pinned to the sha just read rather than plain --force-with-lease, which needs a
        # remote-tracking ref this push does not have: the build repo is addressed by URL so that
        # its token never lands in .git/config.
        lease = f"refs/heads/{branch}:{remote_before}" if force and remote_before else None
        print(f"pushing HEAD -> {REPO_SLUG} {branch}")
        if not push_once(f"HEAD:refs/heads/{branch}", env, lease=lease):
            print("that push did not complete; sending the history in slices instead")
            push_in_slices(branch, env)
            if not push_once(f"HEAD:refs/heads/{branch}", env, lease=lease):
                fail("the final slice would not go through")
        # Rather than trust the exit code of a command whose stderr we let through, confirm the
        # remote tip really is our commit.
        remote = remote_head(branch, env)
        if remote != local:
            fail(
                f"{branch} on {REPO_SLUG} is at {remote[:12] or 'nothing'}, not {local[:12]}\n"
                "       if the build repo has commits yours do not, re-run with --force"
            )
        print(f"pushed {local[:12]}")
    finally:
        holder.cleanup()


def latest_run(branch: str) -> dict | None:
    data = api(f"/repos/{REPO_SLUG}/actions/runs?branch={branch}&per_page=1")
    runs = data.get("workflow_runs") or []
    return runs[0] if runs else None


def wait_for_run(branch: str, after: str | None, timeout: float = 180.0) -> dict | None:
    """The push trigger takes a few seconds to show up; anything longer means it did not fire."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        run = latest_run(branch)
        if run and run.get("id") != after:
            return run
        time.sleep(5.0)
    return None


def watch(run: dict) -> int:
    run_id = run["id"]
    print(f"run {run_id}: {run['html_url']}")
    last = ""
    while True:
        run = api(f"/repos/{REPO_SLUG}/actions/runs/{run_id}")
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

    check_token_file()
    print(f"repo: {REPO_SLUG}   branch: {branch}")

    if args.dispatch:
        api(
            f"/repos/{REPO_SLUG}/actions/workflows/{WORKFLOW_FILE}/dispatches",
            method="POST",
            body={"ref": branch},
        )
        print("dispatched")
        before = None
    else:
        check_clean(args.allow_dirty)
        previous = latest_run(branch)
        before = previous.get("id") if previous else None
        push(branch, args.force)

    run = wait_for_run(branch, before)
    if run is None:
        fail(
            "no run appeared within 3 minutes\n"
            f"       check {'https://github.com/' + REPO_SLUG}/actions"
        )
    if args.no_watch:
        print(f"run {run['id']}: {run['html_url']}")
        return 0
    return watch(run)


if __name__ == "__main__":
    sys.exit(main())
