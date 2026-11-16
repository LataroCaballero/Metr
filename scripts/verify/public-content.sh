#!/usr/bin/env bash
# Usage: scripts/verify/public-content.sh [--repo DIR]     scan a repository (default: this one)
#        scripts/verify/public-content.sh --self-test       prove the gate fails what it must
# T-04-22 / D-22: nothing private may reach the public repository. Three layers over three sources.
#   sources: the content of every text file in the HEAD tree; every line ADDED by any commit reachable
#            from any local ref (pushing a branch publishes its whole history); every tracked file name and
#            every file name any commit ever held.
#   identity layer: the owner's home directory, account name, git e-mail, computer name and local host
#            name, read at RUN TIME (this script never contains them). No allowlist. Skipped under
#            METR_CI=1, because a CI runner's identity is not the owner's.
#   path layer: the three machine-path roots (users, volumes, per-user temp folders). A hit passes only
#            when an exact ALLOW entry covers every occurrence on its line, with a reason.
#   name layer: planning files, logs, .DS_Store, xcuserdata, and names holding an identity value.
#   history-only findings (in the history, not in the tree) are decided by the HISTORY_DECISIONS table:
#            pending (listed, nothing is pushed while any is pending) or approved (owner's words, date).
# Prints PUBLIC-CONTENT ALLOWED / PENDING / NOTE lines, then
#   "PUBLIC-CONTENT OK files=<n> commits=<n> allowed=<n> pending=<n> identity=<0|skipped>"
# or "FAIL: <where>: <text> (<identity|path|name>)" lines and exit 1. --self-test prints
# "PUBLIC-CONTENT SELF-TEST OK".
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
REPO=""
MODE="scan"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) [ "$#" -ge 2 ] || { echo "usage: public-content.sh [--repo DIR] | --self-test" >&2; exit 2; }
            REPO="$2"; shift 2 ;;
    --self-test) MODE="self-test"; shift ;;
    *) echo "usage: public-content.sh [--repo DIR] | --self-test" >&2; exit 2 ;;
  esac
done
if [ -z "$REPO" ]; then REPO="$(git -C "$(dirname "$SELF")" rev-parse --show-toplevel)"; fi

# Identity values are gathered here, in the environment, and never stored.
export PC_HOME="${HOME:-}"
export PC_ACCOUNT="$(id -un 2>/dev/null || true)"
export PC_EMAIL="$(git -C "$REPO" config user.email 2>/dev/null || git config user.email 2>/dev/null || true)"
export PC_COMPUTER="$(scutil --get ComputerName 2>/dev/null || true)"
export PC_LOCALHOST="$(scutil --get LocalHostName 2>/dev/null || true)"
export PC_REPO="$REPO" PC_SELF="$SELF" PC_MODE="$MODE"
if [ "${METR_CI:-0}" = "1" ] || [ "${GITHUB_ACTIONS:-}" = "true" ]; then export PC_SKIP_IDENTITY=1; else export PC_SKIP_IDENTITY=0; fi

exec python3 -I - <<'PY'
import fnmatch, os, re, subprocess, sys, tempfile, shutil

REPO = os.environ["PC_REPO"]
SELF = os.environ["PC_SELF"]
MODE = os.environ["PC_MODE"]
SKIP_IDENTITY = os.environ["PC_SKIP_IDENTITY"] == "1"

# Path roots are written in pieces so this file never contains one whole (it must not match itself).
U, V, F = "/Us" + "ers/", "/Vol" + "umes/", "/var/fol" + "ders/"
PATH_RE = re.compile(re.escape(U) + "|" + re.escape(V) + "|" + re.escape(F))

# Tokens used in the tables below: {U} {V} {F} {P} (private var folders) {S} (system volumes).
TOK = {"{U}": U, "{V}": V, "{F}": F, "{P}": "/private" + F, "{S}": "/System" + V}
def expand(s):
    for k, v in TOK.items():
        s = s.replace(k, v)
    return s

# <file glob>|<exact substring>|<reason>. Exact substrings only, never a whole directory or a bare root.
# Every occurrence of a path root on a line must lie inside an entry's substring for the line to pass.
ALLOW_RAW = [
    ("scripts/env.sh", "{V}XcodeDev", "the build volume of the developer machine; a build-script convention, no account data"),
    ("scripts/preflight.sh", "{V}XcodeDev/Xcode.app", "the developer machine's Xcode on the build volume; no account data"),
    ("scripts/preflight.sh", "{V}Lexar/XcodeDev.sparsebundle", "the build volume's sparsebundle on the external drive; no account data"),
    ("scripts/verify/volumes-vs-diskutil.sh", "{V}*", "generic glob over mount points in a comment; no real path"),
    ("scripts/verify/volumes-vs-diskutil.sh", "{V}.*$", "generic regex over mount points; no real path"),
    ("Packages/MetrKit/Sources/MetrCore/InstallLocation.swift", 'hasPrefix("{V}")', "the disk-image rule itself: a mounted image lives under the volumes root"),
    ("Packages/MetrKit/Tests/MetrCoreTests/ProcessClassifierTests.swift", "{U}x/WindowServer", "placeholder path in a test fixture"),
    ("Packages/MetrKit/Tests/MetrCoreTests/ProcessGroupingTests.swift", "{U}x/my.application/bin/tool", "placeholder path in a test fixture"),
    ("Packages/MetrKit/Tests/MetrCoreTests/VolumeClassifierTests.swift", "{V}\\(name)", "interpolated fixture volume path"),
    ("Packages/MetrKit/Tests/MetrCoreTests/VolumeClassifierTests.swift", "{V}Lexar", "fixture volume path for the classifier test"),
    ("Packages/MetrKit/Tests/MetrCoreTests/VolumeClassifierTests.swift", "{V}XcodeDev", "fixture volume path for the classifier test"),
    ("Packages/MetrKit/Tests/MetrCoreTests/VolumeClassifierTests.swift", "{V}Odd", "fixture volume path for the classifier test"),
    ("Packages/MetrKit/Tests/MetrCoreTests/VolumeClassifierTests.swift", "{S}Data", "the system data volume path, the same on every Mac"),
    ("Packages/MetrKit/Tests/MetrSystemTests/DiskCollectorTests.swift", "{V}metr-does-not-exist-XYZ", "a deliberately absent mount point"),
    ("Packages/MetrKit/Tests/MetrCoreTests/LoginItemProjectionTests.swift", "{U}u/Downloads/Metr.app", "placeholder install path in a test fixture"),
    ("Packages/MetrKit/Tests/MetrCoreTests/LoginItemProjectionTests.swift", "{P}x/AppTranslocation/ABC/d/Metr.app", "the generic translocation path form, with placeholder segments"),
    ("Packages/MetrKit/Tests/MetrCoreTests/LoginItemProjectionTests.swift", "{V}Metr/Metr.app", "the disk-image path of the app's own volume name"),
    ("Packages/MetrKit/Tests/MetrCoreTests/LoginItemProjectionTests.swift", "{U}u/Library/Developer/Xcode/DerivedData/x/Build/Products/Debug/Metr.app", "placeholder DerivedData path in a test fixture"),
    ("Packages/MetrKit/Tests/MetrCoreTests/InstallLocationTests.swift", "{P}x/AppTranslocation/ABC/d/Metr.app", "the generic translocation path form, with placeholder segments"),
    ("Packages/MetrKit/Tests/MetrCoreTests/InstallLocationTests.swift", "{V}Metr/Metr.app", "the disk-image path of the app's own volume name"),
    ("Packages/MetrKit/Tests/MetrCoreTests/InstallLocationTests.swift", "{V}Data/Metr.app", "placeholder volume path in a test fixture"),
    ("Packages/MetrKit/Tests/MetrCoreTests/InstallLocationTests.swift", "{U}u/Metr.app", "placeholder install path in a test fixture"),
    ("Packages/MetrKit/Tests/MetrCoreTests/InstallLocationTests.swift", "{V}Dev/metr-build/abc/DerivedData/Build/Products/Release/Metr.app", "placeholder build-volume path in a test fixture"),
    ("Packages/MetrKit/Tests/MetrCoreTests/InstallLocationTests.swift", "{V}Dev/metr-build/abc/shipped/1.0.0/Metr.app", "placeholder build-volume path in a test fixture"),
    ("Packages/MetrKit/Tests/MetrCoreTests/InstallLocationTests.swift", "{U}u/Library/Developer/Xcode/DerivedData/x/Metr.app", "placeholder DerivedData path in a test fixture"),
    ("Packages/MetrKit/Tests/MetrCoreTests/InstallLocationTests.swift", "{U}u/Downloads/Metr.app", "placeholder install path in a test fixture"),
    ("Packages/MetrKit/Tests/MetrCoreTests/InstallLocationTests.swift", "{U}u/metr-build-notes/Metr.app", "placeholder path in a test fixture"),
    ("Packages/MetrKit/Tests/MetrCoreTests/InstallLocationTests.swift", "{U}u/MyDerivedData/Metr.app", "placeholder path in a test fixture"),
    ("Packages/MetrKit/Tests/MetrCoreTests/InstallLocationTests.swift", "{U}u/Applications/Metr.app", "placeholder path in a test fixture"),
]
ALLOW = [(g, expand(s), r) for g, s, r in ALLOW_RAW]

# <commit>|<path>|<pending or approved>|<reason>. An approved entry needs the owner's words and the date.
HISTORY_DECISIONS = [
    ("52940e1", ".planning/PROJECT.md", "approved",
     "owner approved 2026-11-16: \"solo describe el producto, nada personal\" (it only describes the product, nothing personal); the first commit added it and 2dd37af removed it, both on main and the work branch"),
]

def git(*args, text=True):
    r = subprocess.run(["git", "-c", "core.quotepath=off", "-C", REPO] + list(args),
                       capture_output=True, check=True)
    return r.stdout.decode("utf-8", "replace") if text else r.stdout

def identity_checks():
    vals = []
    home = os.environ.get("PC_HOME", "")
    acct = os.environ.get("PC_ACCOUNT", "")
    for v in (home, os.environ.get("PC_EMAIL", ""), os.environ.get("PC_COMPUTER", ""), os.environ.get("PC_LOCALHOST", "")):
        v = v.strip()
        if len(v) >= 4:
            vals.append(re.compile(re.escape(v), re.I))
    acct = acct.strip()
    if len(acct) >= 4:
        vals.append(re.compile(r"(?<![A-Za-z0-9_])" + re.escape(acct) + r"(?![A-Za-z0-9_])", re.I))
    return vals

def run_scan():
    ident = [] if SKIP_IDENTITY else identity_checks()
    fails, allowed, pending_lines, notes = [], [], [], []
    seen_tree = set()
    allowed_keys = set()

    def has_identity(s):
        return any(p.search(s) for p in ident)

    def allow_reason(path, line):
        hits = [(s, r) for g, s, r in ALLOW if fnmatch.fnmatchcase(path, g) and s in line]
        if not hits:
            return None
        rest = line
        for s, _ in sorted(hits, key=lambda h: -len(h[0])):
            rest = rest.replace(s, "")
        return None if PATH_RE.search(rest) else hits[0][1]

    def name_kind(p):
        if p.startswith(".planning/") or "/.planning/" in p:
            return "planning file"
        if p.endswith(".log") or p.endswith(".out"):
            return "log file"
        if os.path.basename(p) == ".DS_Store":
            return "DS_Store"
        if "xcuserdata" in p:
            return "xcuserdata"
        if has_identity(p):
            return "name holds an identity value"
        return None

    # sources 1 and 3a: the HEAD tree
    files = [f for f in git("ls-tree", "-r", "-z", "--name-only", "HEAD").split("\0") if f]
    for f in files:
        k = name_kind(f)
        if k:
            fails.append(f"FAIL: HEAD:{f}: {k} (name)")
        try:
            data = git("show", f"HEAD:{f}", text=False)
        except subprocess.CalledProcessError:
            continue
        if b"\0" in data[:8000]:
            continue
        for n, line in enumerate(data.decode("utf-8", "replace").split("\n"), 1):
            if has_identity(line):
                fails.append(f"FAIL: HEAD:{f}:{n}: <redacted: matches an owner identity value> (identity)")
                seen_tree.add((f, line))
            elif PATH_RE.search(line):
                reason = allow_reason(f, line)
                seen_tree.add((f, line))
                if reason is None:
                    fails.append(f"FAIL: HEAD:{f}:{n}: {line.strip()[:140]} (path)")
                else:
                    allowed.append(f"PUBLIC-CONTENT ALLOWED {f}:{n}: {reason}")
                    allowed_keys.add((f, reason))

    commits = git("rev-list", "--all").split()
    commit_set = set(commits)

    def commit_reachable(prefix):
        return any(c.startswith(prefix) for c in commit_set)

    decisions = {}
    for c, p, status, reason in HISTORY_DECISIONS:
        if not commit_reachable(c):
            notes.append(f"PUBLIC-CONTENT NOTE stale history entry {c}")
            continue
        decisions[(c, p)] = (status, reason)

    def decide(commit, path, what, kind):
        """A finding that exists in the history only. Returns a line to print or None."""
        for (c, p), (status, reason) in decisions.items():
            if p == path and commit.startswith(c):
                if status == "pending":
                    pending_lines.append(f"PUBLIC-CONTENT PENDING {commit[:7]}:{path}: {what} (owner decision, Task 2)")
                else:
                    allowed.append(f"PUBLIC-CONTENT ALLOWED {commit[:7]}:{path}: {reason}")
                return
        fails.append(f"FAIL: {commit[:7]}:{path}: {what} ({kind})")

    # source 3b: every name any commit ever held (oldest first, so the first holder is reported)
    head_names = set(files)
    first_holder = {}
    cur = None
    for ln in git("log", "--all", "--reverse", "--format=@@C %H", "--name-only").split("\n"):
        if ln.startswith("@@C "):
            cur = ln[4:]
        elif ln:
            first_holder.setdefault(ln, cur)
    for p, c in sorted(first_holder.items()):
        if p in head_names:
            continue
        k = name_kind(p)
        if k:
            decide(c, p, k, "name")

    # source 2: every added line of every commit reachable from any ref
    hist_seen = set()
    commit = path = None
    rem_add = rem_del = 0
    hunk_re = re.compile(r"^@@ -\d+(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")
    for ln in git("log", "--all", "-p", "--unified=0", "--no-color", "--no-renames", "--format=@@COMMIT %H").split("\n"):
        if rem_add == 0 and rem_del == 0:
            if ln.startswith("@@COMMIT "):
                commit = ln[9:]; continue
            if ln.startswith("+++ "):
                path = ln[6:] if ln.startswith("+++ b/") else None
                continue
            m = hunk_re.match(ln)
            if m:
                rem_del = int(m.group(1)) if m.group(1) is not None else 1
                rem_add = int(m.group(3)) if m.group(3) is not None else 1
            continue
        if ln.startswith("-") and rem_del > 0:
            rem_del -= 1; continue
        if ln.startswith("+") and rem_add > 0:
            rem_add -= 1
            text = ln[1:]
            if path is None:
                continue
            if has_identity(text):
                key = (path, "identity")
                if (path, text) in seen_tree or key in hist_seen:
                    continue
                hist_seen.add(key)
                fails.append(f"FAIL: {commit[:7]}:{path}: <redacted: matches an owner identity value> (identity)")
            elif PATH_RE.search(text):
                if (path, text) in seen_tree:
                    continue
                reason = allow_reason(path, text)
                if reason is not None:
                    if (path, reason) not in allowed_keys:
                        allowed_keys.add((path, reason))
                        allowed.append(f"PUBLIC-CONTENT ALLOWED {commit[:7]}:{path}: {reason} (history)")
                    continue
                key = (path, text)
                if key in hist_seen:
                    continue
                hist_seen.add(key)
                if path in head_names:
                    fails.append(f"FAIL: {commit[:7]}:{path}: {text.strip()[:140]} (path)")
                else:
                    decide(commit, path, "path in an old version: " + text.strip()[:100], "path")
        # lines starting with a backslash ("No newline at end of file") consume nothing

    return fails, allowed, pending_lines, notes, len(files), len(commits)

def report():
    fails, allowed, pending, notes, nfiles, ncommits = run_scan()
    return fails, allowed, pending, notes, nfiles, ncommits

def scan_main():
    fails, allowed, pending, notes, nfiles, ncommits = report()
    for ln in notes + allowed + pending:
        print(ln)
    if fails:
        for ln in fails:
            print(ln)
        sys.exit(1)
    ident = "skipped" if SKIP_IDENTITY else "0"
    print(f"PUBLIC-CONTENT OK files={nfiles} commits={ncommits} allowed={len(allowed)} pending={len(pending)} identity={ident}")

def self_test():
    # Plants one finding of each kind in a throwaway repository and demands the gate reports exactly those.
    home = os.environ.get("PC_HOME", "")
    if len(home) < 4:
        print("FAIL: self-test needs a home directory of at least 4 characters", file=sys.stderr); sys.exit(1)
    tmp = tempfile.mkdtemp(prefix="pc-selftest-")
    try:
        def g(*a):
            subprocess.run(["git", "-C", tmp] + list(a), check=True, capture_output=True)
        g("init", "-q"); g("config", "user.email", "selftest@example.invalid"); g("config", "user.name", "selftest")
        with open(os.path.join(tmp, "a.txt"), "w") as f: f.write(f"home is {home}\n")
        with open(os.path.join(tmp, "b.txt"), "w") as f: f.write(f"see {V}SomeDrive/file\n")
        with open(os.path.join(tmp, "debug.log"), "w") as f: f.write("nothing private\n")
        g("add", "."); g("commit", "-q", "-m", "plant")
        env = {k: v for k, v in os.environ.items() if k not in ("METR_CI", "GITHUB_ACTIONS")}
        def run():
            r = subprocess.run(["bash", SELF, "--repo", tmp], env=env, capture_output=True, text=True)
            return r.returncode, [l for l in r.stdout.split("\n") if l.startswith("FAIL:")]
        rc, out = run()
        kinds = sorted(re.search(r"\((\w+)\)$", l).group(1) for l in out)
        if rc == 0 or kinds != ["identity", "name", "path"]:
            print(f"FAIL: self-test expected exactly identity, path and name findings, got {kinds} (rc={rc})"); sys.exit(1)
        g("rm", "-q", "debug.log"); g("commit", "-q", "-m", "remove the log")
        rc, out = run()
        hist = [l for l in out if "debug.log" in l and "(name)" in l and "HEAD:" not in l]
        if rc == 0 or not hist:
            print("FAIL: self-test: removing a file in a later commit hid its name finding"); sys.exit(1)
        print("PUBLIC-CONTENT SELF-TEST OK")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

if MODE == "self-test":
    self_test()
else:
    scan_main()
PY
