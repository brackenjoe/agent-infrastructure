#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Joe Fernandez
"""Promote allowlisted files from an agent's scratch/ to its artifacts/.

    python3 -I tools/security-audit-promote.py promote AGENT-DIR REL [REL...]
                                               [--max-file N] [--max-total N]
    python3 -I tools/security-audit-promote.py selfcheck

The trusted, parent-side promotion step of a security-audit run, run after the
sandbox and all its processes have ended. AGENT-DIR is <out>/agents/<id>; its
scratch/ is untrusted, its artifacts/ is parent-owned. Each REL is a path
relative to scratch/, copied to the same path under artifacts/ only if it is a
plain, stable, single-link regular file within the byte bounds. The procedure
is tools/security-audit-skill/SKILL.md "Write isolation", steps 1-11: both
root directories are opened once, no-follow, and everything after is a
directory-relative, no-follow operation on retained descriptors; nothing is
reopened by path. Never recurses, globs or extracts; refused entries stay in
scratch (this tool never deletes from scratch).

N is a positive integer of bytes, optionally suffixed K (KiB) or M (MiB).
Defaults: --max-file 1M, --max-total 4M (the total counts promoted bytes).

Output, one line per REL, then a total:
    ok    promoted REL (N bytes)
    FAIL  refused REL: reason
    promoted K of M file(s), T bytes

selfcheck builds a throwaway tree under tempfile.mkdtemp() and exercises every
refusal against the same promote function, checking the refusal reason.

Exit 0 every file promoted (or every selfcheck case ok), 1 any file refused,
bad agent directory or any selfcheck FAIL, 2 usage. Linux only; standard
library only.
"""

import errno
import os
import re
import shutil
import signal
import socket
import stat
import sys
import tempfile

AGENT_ID = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
WIN_DEVICES = {"con", "prn", "aux", "nul"} | {f"com{i}" for i in range(1, 10)} | {
    f"lpt{i}" for i in range(1, 10)}
USAGE = ("usage: security-audit-promote.py promote AGENT-DIR REL [REL...] "
         "[--max-file N] [--max-total N]\n"
         "       security-audit-promote.py selfcheck")

DEFAULT_MAX_FILE = 1024 * 1024
DEFAULT_MAX_TOTAL = 4 * 1024 * 1024
MAX_COMPONENT = 255
MAX_PATH = 4096
CHUNK = 65536

DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
SRC_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
DST_FLAGS = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC

# Test seam: selfcheck sets this; promotion calls it with the REL between the
# read (step 5) and the second fstat (step 6). Not reachable from the CLI.
_after_read = None


class Fail(Exception):
    """Exit 1: bad agent directory or unusable input."""


class Refused(Exception):
    """One REL was refused; the message is the reason."""


# ------------------------------------------------------------ validation

def validate_rel(rel, seen):
    """Step 1. Raises Refused. Adds rel to seen when it is well formed."""
    if not rel:
        raise Refused("empty path")
    if "\x00" in rel or any(ord(c) < 0x20 or ord(c) == 0x7F for c in rel):
        raise Refused("NUL or control character in path")
    if rel.startswith("/"):
        raise Refused("absolute path")
    comps = rel.split("/")
    if any(c == "" for c in comps):
        raise Refused("empty component (// or trailing /)")
    if any(c in (".", "..") for c in comps):
        raise Refused("'.' or '..' component")
    if len(os.fsencode(rel)) > MAX_PATH:
        raise Refused(f"path longer than {MAX_PATH} bytes")
    if any(len(os.fsencode(c)) > MAX_COMPONENT for c in comps):
        raise Refused(f"component longer than {MAX_COMPONENT} bytes")
    if rel in seen:
        raise Refused("duplicate path in this call")
    seen.add(rel)
    return comps


def shown(rel):
    return rel if re.fullmatch(r"[A-Za-z0-9._/-]+", rel) else repr(rel)


# ------------------------------------------------------- classification

def type_name(mode):
    """Name of a non-regular file type, or None for a regular file."""
    if stat.S_ISREG(mode):
        return None
    for test, name in ((stat.S_ISLNK, "symlink"), (stat.S_ISFIFO, "fifo"),
                       (stat.S_ISSOCK, "socket"),
                       (stat.S_ISCHR, "character device"),
                       (stat.S_ISBLK, "block device"),
                       (stat.S_ISDIR, "directory")):
        if test(mode):
            return name
    return "unknown file type"


def classify(fd, st, max_file, max_total, running_total):
    """Steps 3-4 on an open descriptor and its fstat. Raises Refused.

    fd must be the descriptor st came from; the check is by device and inode.
    """
    cur = os.fstat(fd)
    if (cur.st_dev, cur.st_ino) != (st.st_dev, st.st_ino):
        raise Refused("fstat does not belong to the descriptor")
    name = type_name(st.st_mode)
    if name:
        raise Refused(f"not a regular file: {name}")
    if st.st_nlink != 1:
        raise Refused(f"hard link: link count {st.st_nlink}")
    if st.st_size > max_file:
        raise Refused(f"oversized: {st.st_size} bytes exceeds the {max_file} byte per-file bound")
    if running_total + st.st_size > max_total:
        raise Refused(f"cumulative bound: {running_total} + {st.st_size} bytes exceeds {max_total}")


# ------------------------------------------------------------- the walk

def _open_dir(parent, name, side):
    """Open directory NAME under PARENT without following links; return fd."""
    try:
        fd = os.open(name, DIR_FLAGS, dir_fd=parent)
    except OSError as e:
        if e.errno == errno.ELOOP:
            raise Refused(f"symlinked {side}component")
        if e.errno == errno.ENOTDIR:
            # Linux reports a symlink opened O_DIRECTORY|O_NOFOLLOW as ENOTDIR;
            # look only to word the reason.
            try:
                if stat.S_ISLNK(os.stat(name, dir_fd=parent, follow_symlinks=False).st_mode):
                    raise Refused(f"symlinked {side}component")
            except OSError:
                pass
            raise Refused(f"{side}component is not a directory")
        raise Refused(f"cannot open {side}component: {e.strerror}")
    try:
        if not stat.S_ISDIR(os.fstat(fd).st_mode):
            raise Refused(f"{side}component is not a directory")
    except BaseException:
        os.close(fd)
        raise
    return fd


def walk(root_fd, comps, mkdir, side):
    """Step 2 (mkdir False) and step 7 (mkdir True). Returns the last
    directory's fd; the caller closes it when it is not root_fd."""
    cur = root_fd
    try:
        for comp in comps:
            if mkdir:
                try:
                    os.mkdir(comp, 0o700, dir_fd=cur)
                except FileExistsError:
                    pass
                except OSError as e:
                    raise Refused(f"cannot create {side}component: {e.strerror}")
            nxt = _open_dir(cur, comp, side)
            if cur != root_fd:
                os.close(cur)
            cur = nxt
        return cur
    except BaseException:
        if cur != root_fd:
            os.close(cur)
        raise


# ------------------------------------------------------- the promotion

def _open_source(scratch_fd, comps):
    """Steps 2-3: return an open descriptor for the leaf."""
    parent = walk(scratch_fd, comps[:-1], False, "")
    try:
        leaf = comps[-1]
        try:
            lst = os.stat(leaf, dir_fd=parent, follow_symlinks=False)
        except FileNotFoundError:
            raise Refused("no such file")
        except OSError as e:
            raise Refused(f"cannot stat: {e.strerror}")
        name = type_name(lst.st_mode)
        if name:
            raise Refused(f"not a regular file: {name}")
        try:
            fd = os.open(leaf, SRC_FLAGS, dir_fd=parent)
        except OSError as e:
            if e.errno == errno.ELOOP:
                raise Refused("not a regular file: symlink")
            if e.errno == errno.ENXIO:
                raise Refused("not a regular file: cannot be opened (ENXIO)")
            raise Refused(f"cannot open: {e.strerror}")
        try:
            st = os.fstat(fd)
            if (st.st_dev, st.st_ino) != (lst.st_dev, lst.st_ino):
                raise Refused("changed between lstat and open")
        except BaseException:
            os.close(fd)
            raise
        return fd
    finally:
        if parent != scratch_fd:
            os.close(parent)


def _read_bounded(fd, size):
    """Step 5: read at most size + 1 bytes; the count must equal size."""
    chunks = []
    got = 0
    while got < size + 1:
        data = os.read(fd, min(CHUNK, size + 1 - got))
        if not data:
            break
        chunks.append(data)
        got += len(data)
    if got != size:
        raise Refused(f"changed while reading: read {got} bytes, expected {size}")
    return b"".join(chunks)


_IDENTITY = ("st_dev", "st_ino", "st_mode", "st_nlink", "st_size",
             "st_mtime_ns", "st_ctime_ns")


def _write_dest(artifacts_fd, comps, data):
    """Steps 7-8: create the destination exclusively and write data."""
    dparent = walk(artifacts_fd, comps[:-1], True, "destination ")
    try:
        leaf = comps[-1]
        try:
            fd = os.open(leaf, DST_FLAGS, 0o600, dir_fd=dparent)
        except FileExistsError:
            raise Refused("destination exists")
        except OSError as e:
            raise Refused(f"cannot create destination: {e.strerror}")
        try:
            try:
                st = os.fstat(fd)
                if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
                    raise Refused(f"destination is not a single-link regular file "
                                  f"(link count {st.st_nlink})")
                view = memoryview(data)
                while view:
                    view = view[os.write(fd, view):]
                os.fsync(fd)
                if os.fstat(fd).st_size != len(data):
                    raise Refused("destination size differs from the source")
            except BaseException as e:
                try:
                    os.unlink(leaf, dir_fd=dparent)
                except OSError:
                    pass
                if isinstance(e, OSError):
                    raise Refused(f"destination write failed: {e.strerror}")
                raise
        finally:
            os.close(fd)
    finally:
        if dparent != artifacts_fd:
            os.close(dparent)


def promote_one(scratch_fd, artifacts_fd, rel, comps, max_file, max_total, running):
    """Steps 2-8 for one REL. Returns the byte count; raises Refused."""
    fd = _open_source(scratch_fd, comps)
    try:
        st = os.fstat(fd)
        classify(fd, st, max_file, max_total, running)
        data = _read_bounded(fd, st.st_size)
        if _after_read is not None:
            _after_read(rel)
        after = os.fstat(fd)
        diff = [f for f in _IDENTITY if getattr(st, f) != getattr(after, f)]
        if diff:
            raise Refused("changed during copy: " + ", ".join(diff))
    finally:
        os.close(fd)
    _write_dest(artifacts_fd, comps, data)
    return len(data)


def open_agent(agent_dir):
    """Open the two root descriptors. Returns (scratch_fd, artifacts_fd)."""
    path = str(agent_dir).rstrip("/")
    ident = os.path.basename(path)
    if not AGENT_ID.match(ident) or ident in WIN_DEVICES:
        raise Fail(f"not a canonical agent id: {ident!r}")
    try:
        agent_fd = os.open(path, DIR_FLAGS)
    except OSError as e:
        raise Fail(f"cannot open agent directory {path}: {e.strerror}")
    scratch_fd = artifacts_fd = None
    try:
        for name in ("scratch", "artifacts"):
            if name == "artifacts":
                try:
                    os.mkdir("artifacts", 0o700, dir_fd=agent_fd)
                except FileExistsError:
                    pass
                except OSError as e:
                    raise Fail(f"cannot create artifacts: {e.strerror}")
            try:
                fd = os.open(name, DIR_FLAGS, dir_fd=agent_fd)
            except OSError as e:
                why = "symlink" if e.errno in (errno.ELOOP, errno.ENOTDIR) else e.strerror
                raise Fail(f"cannot open {name} of {ident}: {why}")
            if name == "scratch":
                scratch_fd = fd
            else:
                artifacts_fd = fd
            if not stat.S_ISDIR(os.fstat(fd).st_mode):
                raise Fail(f"{name} of {ident} is not a directory")
        result = (scratch_fd, artifacts_fd)
        scratch_fd = artifacts_fd = None
        return result
    finally:
        os.close(agent_fd)
        for fd in (scratch_fd, artifacts_fd):
            if fd is not None:
                os.close(fd)


def promote(agent_dir, rels, max_file=DEFAULT_MAX_FILE, max_total=DEFAULT_MAX_TOTAL):
    """Promote each REL in order. Returns [(rel, ok, bytes_or_reason)].
    Raises Fail when the agent directory cannot be used."""
    scratch_fd, artifacts_fd = open_agent(agent_dir)
    results = []
    seen = set()
    running = 0
    try:
        for rel in rels:
            try:
                comps = validate_rel(rel, seen)
                n = promote_one(scratch_fd, artifacts_fd, rel, comps,
                                max_file, max_total, running)
            except Refused as e:
                results.append((rel, False, str(e)))
            except OSError as e:
                results.append((rel, False, f"unexpected error: {e.strerror or e}"))
            else:
                running += n
                results.append((rel, True, n))
    finally:
        os.close(scratch_fd)
        os.close(artifacts_fd)
    return results


def format_results(results):
    lines = []
    for rel, ok, info in results:
        if ok:
            lines.append(f"ok    promoted {shown(rel)} ({info} bytes)")
        else:
            lines.append(f"FAIL  refused {shown(rel)}: {info}")
    done = [r for r in results if r[1]]
    lines.append(f"promoted {len(done)} of {len(results)} file(s), "
                 f"{sum(r[2] for r in done)} bytes")
    return lines


# ------------------------------------------------------------------ CLI

def parse_size(text):
    m = re.fullmatch(r"([0-9]+)([KkMm]?)", text)
    if not m or int(m.group(1)) == 0:
        raise ValueError(text)
    return int(m.group(1)) * {"": 1, "k": 1024, "m": 1024 * 1024}[m.group(2).lower()]


def cmd_promote(args):
    limits = {"--max-file": DEFAULT_MAX_FILE, "--max-total": DEFAULT_MAX_TOTAL}
    positional = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--":
            positional.extend(args[i + 1:])
            break
        if a.startswith("--max-"):
            name, eq, val = a.partition("=")
            if name not in limits:
                return usage(f"unknown option: {a}")
            if not eq:
                i += 1
                if i >= len(args):
                    return usage(f"{name} needs a value")
                val = args[i]
            try:
                limits[name] = parse_size(val)
            except ValueError:
                return usage(f"{name}: not a positive size (bytes, K or M): {val!r}")
        elif a.startswith("-") and a != "-":
            return usage(f"unknown option: {a}")
        else:
            positional.append(a)
        i += 1
    if len(positional) < 2:
        return usage("promote needs AGENT-DIR and at least one REL")
    try:
        results = promote(positional[0], positional[1:],
                          limits["--max-file"], limits["--max-total"])
    except Fail as e:
        print(f"security-audit-promote: {e}", file=sys.stderr)
        return 1
    for line in format_results(results):
        print(line)
    return 0 if all(r[1] for r in results) else 1


def usage(msg=None):
    if msg:
        print(f"security-audit-promote: {msg}", file=sys.stderr)
    print(USAGE, file=sys.stderr)
    return 2


# ------------------------------------------------------------ selfcheck

class _Timeout(Exception):
    pass


def _tree(root):
    out = []
    for d, dirs, files in os.walk(root):
        for n in dirs + files:
            out.append(os.path.relpath(os.path.join(d, n), root))
    return sorted(out)


def selfcheck():
    failures = 0

    def report(case, good, detail):
        nonlocal failures
        if not good:
            failures += 1
        print(f"{'ok   ' if good else 'FAIL '} {case}  {detail}")

    def expect_refused(case, results, index, needle, extra=True, note=""):
        rel, ok, info = results[index]
        good = (not ok) and needle in str(info) and extra
        report(case, good, f"{shown(rel)} -> "
               f"{'promoted' if ok else 'refused: ' + str(info)}"
               + (f" (expected '{needle}')" if not good else "") + note)

    base = tempfile.mkdtemp(prefix="security-audit-promote-selfcheck-")
    try:
        agent = os.path.join(base, "out", "agents", "selfcheck-1")
        scratch = os.path.join(agent, "scratch")
        arts = os.path.join(agent, "artifacts")
        elsewhere = os.path.join(base, "elsewhere")
        for d in (scratch, arts, elsewhere):
            os.makedirs(d)

        def put(rel, data):
            p = os.path.join(scratch, rel)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "wb") as f:
                f.write(data)
            return p

        def run(rels, max_file=1024, max_total=1500):
            return promote(agent, rels, max_file, max_total)

        # honest
        payload = bytes(range(100))
        put("honest.txt", payload)
        r = run(["honest.txt"])
        art = os.path.join(arts, "honest.txt")
        try:
            st = os.stat(art)
            with open(art, "rb") as f:
                same = f.read() == payload
            good = (r[0][1] and r[0][2] == 100 and same
                    and stat.S_IMODE(st.st_mode) == 0o600 and st.st_nlink == 1)
            report("honest", good, f"100 bytes promoted, bytes equal={same}, "
                   f"mode {stat.S_IMODE(st.st_mode):04o}, nlink {st.st_nlink}")
        except OSError as e:
            report("honest", False, f"artifact missing: {e}")

        # nested
        put("nested/a/honest2.txt", b"nested payload\n")
        r = run(["nested/a/honest2.txt"])
        good = r[0][1] and os.path.isfile(os.path.join(arts, "nested", "a", "honest2.txt"))
        report("nested", good, f"nested/a/honest2.txt promoted ({r[0][2]}); artifacts/nested/a created="
               f"{os.path.isdir(os.path.join(arts, 'nested', 'a'))}")

        # symlinks
        os.symlink("honest.txt", os.path.join(scratch, "link.txt"))
        r = run(["link.txt"])
        expect_refused("symlink-leaf", r, 0, "not a regular file: symlink",
                       not os.path.lexists(os.path.join(arts, "link.txt")))
        os.symlink("/etc/passwd", os.path.join(scratch, "out.txt"))
        before = _tree(arts)
        r = run(["out.txt"])
        expect_refused("symlink-outside", r, 0, "not a regular file: symlink",
                       _tree(arts) == before, "; artifacts unchanged")

        # symlinked component
        put("realdir/f.txt", b"real\n")
        os.symlink("realdir", os.path.join(scratch, "symdir"))
        before = _tree(arts)
        r = run(["symdir/f.txt"])
        expect_refused("symlinked-component", r, 0, "symlinked component",
                       _tree(arts) == before)

        # hard link
        hard = put("hard.txt", b"hard\n")
        os.link(hard, os.path.join(scratch, "hard2.txt"))
        r = run(["hard.txt"])
        expect_refused("hard-link", r, 0, "link count 2",
                       not os.path.exists(os.path.join(arts, "hard.txt")))

        # fifo (must not block)
        os.mkfifo(os.path.join(scratch, "fifo"))

        def on_alarm(signum, frame):
            raise _Timeout()
        old = signal.signal(signal.SIGALRM, on_alarm)
        signal.alarm(10)
        try:
            r = run(["fifo"])
            expect_refused("fifo", r, 0, "not a regular file: fifo",
                           not os.path.exists(os.path.join(arts, "fifo")),
                           "; did not block")
        except _Timeout:
            report("fifo", False, "blocked for 10 s")
        finally:
            signal.alarm(0)
            signal.signal(signal.SIGALRM, old)

        # socket
        sk = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            try:
                sk.bind(os.path.join(scratch, "sock"))
            except OSError:
                dfd = os.open(scratch, os.O_RDONLY | os.O_DIRECTORY)
                try:
                    sk.bind(f"/proc/self/fd/{dfd}/sock")
                finally:
                    os.close(dfd)
            r = run(["sock"])
            expect_refused("socket", r, 0, "not a regular file: socket",
                           not os.path.exists(os.path.join(arts, "sock")))
        except OSError as e:
            report("socket", False, f"could not bind a socket: {e}")
        finally:
            sk.close()

        # device: mknod needs privilege, so classify an fd of /dev/null
        fd = os.open("/dev/null", os.O_RDONLY | os.O_CLOEXEC)
        try:
            try:
                classify(fd, os.fstat(fd), 1024, 1500, 0)
                report("device", False, "/dev/null was accepted")
            except Refused as e:
                report("device", "character device" in str(e),
                       f"not planted (mknod needs privilege); classifier on an fd of "
                       f"/dev/null -> refused: {e}")
        finally:
            os.close(fd)

        # directory
        os.mkdir(os.path.join(scratch, "adir"))
        r = run(["adir"])
        expect_refused("directory", r, 0, "not a regular file: directory",
                       not os.path.exists(os.path.join(arts, "adir")))

        # oversized
        put("big.bin", b"x" * 1025)
        r = run(["big.bin"])
        expect_refused("oversized", r, 0, "oversized",
                       not os.path.exists(os.path.join(arts, "big.bin")))

        # cumulative
        put("cum1.bin", b"a" * 800)
        put("cum2.bin", b"b" * 800)
        r = run(["cum1.bin", "cum2.bin"])
        expect_refused("cumulative", r, 1, "cumulative bound",
                       r[0][1] and os.path.isfile(os.path.join(arts, "cum1.bin"))
                       and not os.path.exists(os.path.join(arts, "cum2.bin")),
                       "; first promoted (800), total bound 1500")

        # changing
        victim = put("changing.txt", b"c" * 50)

        def grow(rel):
            with open(victim, "ab") as f:
                f.write(b"!")
        global _after_read
        _after_read = grow
        try:
            r = run(["changing.txt"])
        finally:
            _after_read = None
        expect_refused("changing", r, 0, "changed",
                       not os.path.exists(os.path.join(arts, "changing.txt")),
                       "; no artifact left behind")

        # bad paths
        bad = [("", "empty path"), ("/etc/passwd", "absolute"),
               ("../x", "'..'"), ("a/../b", "'..'"), ("./honest.txt", "'.'"),
               ("a//b", "empty component"), ("honest.txt/", "empty component"),
               ("a\nb", "control character")]
        before = _tree(arts)
        r = run([b for b, _ in bad])
        for i, (b, needle) in enumerate(bad):
            expect_refused("bad-path", r, i, needle)
        report("bad-path-clean", _tree(arts) == before,
               "artifacts unchanged by the bad paths")

        # duplicate
        put("dup.txt", b"dup\n")
        r = run(["dup.txt", "dup.txt"])
        good = r[0][1] and not r[1][1] and "duplicate" in r[1][2]
        report("duplicate", good, f"first {'promoted' if r[0][1] else 'refused'}, "
               f"second {'promoted' if r[1][1] else 'refused: ' + str(r[1][2])}")

        # dest-exists
        with open(os.path.join(arts, "exists.txt"), "wb") as f:
            f.write(b"original")
        put("exists.txt", b"different")
        r = run(["exists.txt"])
        with open(os.path.join(arts, "exists.txt"), "rb") as f:
            kept = f.read()
        expect_refused("dest-exists", r, 0, "destination exists", kept == b"original",
                       f"; artifact still holds {kept!r}")

        # dest-symlink
        os.symlink(elsewhere, os.path.join(arts, "evil"))
        put("evil/x.txt", b"escape\n")
        r = run(["evil/x.txt"])
        expect_refused("dest-symlink", r, 0, "symlinked destination component",
                       os.listdir(elsewhere) == [], "; elsewhere still empty")

        # agent-dir
        agents = os.path.join(base, "out", "agents")
        for name in ("CON", "nul"):
            os.makedirs(os.path.join(agents, name, "scratch"))
            try:
                promote(os.path.join(agents, name), ["x"], 1024, 1500)
                report(f"agent-dir-{name}", False, "accepted")
            except Fail as e:
                report(f"agent-dir-{name}", "canonical agent id" in str(e),
                       f"refused: {e}")
        symagent = os.path.join(agents, "symscratch")
        os.makedirs(symagent)
        os.symlink(elsewhere, os.path.join(symagent, "scratch"))
        try:
            promote(symagent, ["x"], 1024, 1500)
            report("agent-dir-symlinked-scratch", False, "accepted")
        except Fail as e:
            report("agent-dir-symlinked-scratch", "scratch" in str(e) and "symlink" in str(e),
                   f"refused: {e}")
    finally:
        shutil.rmtree(base, ignore_errors=True)
    print(f"selfcheck: {'FAILED, ' + str(failures) + ' case(s)' if failures else 'all cases ok'}")
    return 1 if failures else 0


def main(argv):
    if not argv:
        return usage()
    cmd, rest = argv[0], argv[1:]
    if cmd == "promote":
        return cmd_promote(rest)
    if cmd == "selfcheck":
        return selfcheck() if not rest else usage("selfcheck takes no arguments")
    return usage(f"unknown subcommand: {cmd}")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
