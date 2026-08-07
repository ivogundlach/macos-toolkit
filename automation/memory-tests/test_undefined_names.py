#!/usr/bin/env python3
"""Every global name the memory tools load at runtime must actually exist.

WHY THIS IS A CONTRACT TEST AND NOT A LINTER. On 2026-07-31 the daemon shipped
with `vector_matrix.load(self.db, DB, cs.get_meta)` in one method while
`chunk_store as cs` was imported as a LOCAL in a different method. Python binds
globals at call time, so nothing failed until the code ran -- and when it ran it
hit the fail-soft handler wrapping it, which did its job: logged the reason and
dropped to the slower path. The system stayed correct and got quietly slower.
That is the worst shape a bug can have here, because every safety net in this
codebase is built to absorb exactly that and keep going.

A NameError inside an `except Exception` is invisible by construction, which is
the same reason the other suites exist. This one is cheap and exact: it never
executes the tools, it disassembles them and checks that every LOAD_GLOBAL
resolves against the module's own bindings plus builtins. LOAD_GLOBAL is emitted
only for genuine global reads -- attributes, locals and closures use different
opcodes -- so there is nothing to heuristically guess at and no false positives
to teach people to ignore. A suite that cries wolf gets skipped, and a skipped
suite is worse than no suite.

No third-party linter is used on purpose: this runs unattended, and adding a dev
dependency to satisfy a 30-line check would make the check the fragile part.
"""
import builtins, dis, sys
from pathlib import Path

TOOLS = Path("/Users/YOUR_USERNAME/.memory/tools")
FAILS = []


def check(name, cond, detail=""):
    print(f"  {'ok  ' if cond else 'FAIL'}  {name}{'  ' + detail if detail else ''}")
    if not cond:
        FAILS.append(name)


def walk(code):
    yield code
    for const in code.co_consts:
        if hasattr(const, "co_code"):
            yield from walk(const)


def bound_names(code):
    """Every name this module binds at module level, or declares global anywhere."""
    names = set()
    for c in walk(code):
        for ins in dis.get_instructions(c):
            if ins.opname in ("STORE_NAME", "DELETE_NAME", "STORE_GLOBAL"):
                names.add(ins.argval)
    return names


def undefined(path):
    src = path.read_text(errors="replace")
    try:
        code = compile(src, str(path), "exec")
    except SyntaxError as e:
        return [f"does not compile: {e}"]
    known = bound_names(code) | set(dir(builtins)) | {"__file__", "__name__", "__doc__"}
    bad = []
    for c in walk(code):
        for ins in dis.get_instructions(c):
            if ins.opname == "LOAD_GLOBAL" and ins.argval not in known:
                bad.append(f"{ins.argval} (line {ins.positions.lineno}, in {c.co_name})")
    return bad


# Scripts here have no .py suffix, so glob on content rather than extension:
# memory-query-daemon is the file this test was written for and it is not a *.py.
targets = sorted(p for p in TOOLS.iterdir()
                 if p.is_file() and not p.name.startswith(".")
                 and (p.suffix == ".py"
                      or p.read_bytes()[:2] == b"#!" and b"python" in p.read_bytes()[:64]))

# Positive control. A check that can only ever pass is indistinguishable from a
# check that is broken, and this one passing on every file is the expected
# result -- so it has to be shown catching the real bug before its silence
# means anything. This is that bug, reduced: an import that is local to one
# method being read from another.
import tempfile
_ctl = Path(tempfile.mkdtemp()) / "control.py"
_ctl.write_text(
    "class D:\n"
    "    def load(self):\n"
    "        import chunk_store as cs\n"
    "        self.x = cs.get_meta\n"
    "    def load_matrix(self):\n"
    "        return cs.get_meta\n")
_hits = undefined(_ctl)
check("the check detects the bug it was written for",
      any(h.startswith("cs ") for h in _hits), f"got {_hits}")
_ctl.write_text("import chunk_store as cs\n"
                "class D:\n"
                "    def load_matrix(self):\n"
                "        return cs.get_meta\n")
check("and stays quiet once it is fixed", undefined(_ctl) == [])

print(f"undefined global names across {len(targets)} memory tools")
check("found the tools to check", len(targets) >= 8, f"{len(targets)} files")
for p in targets:
    bad = undefined(p)
    check(p.name, not bad, "" if not bad else "; ".join(bad[:4]))

print(f"\n{'FAILED: ' + ', '.join(FAILS) if FAILS else 'every global name resolves'}")
sys.exit(1 if FAILS else 0)
