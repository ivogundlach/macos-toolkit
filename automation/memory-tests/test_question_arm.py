"""Arm D invariants — the ones that break INVISIBLY.

Every check here is for a failure that produces plausible results rather than an
error: an arm that silently reorders when it is supposed to be disabled, a side
channel that serves the previous query's rows, or a question splitter that fuses
five questions into one string that matches none of them.
"""
import os
import sys

sys.path.insert(0, os.path.expanduser("~/.memory/tools"))
import fusion
import question_index as qi

fails = []


def check(n, c, d=""):
    print(("  ok  " if c else "  FAIL") + f" {n} {d}")
    if not c:
        fails.append(n)


docs = [("memory", f"n{i}.md", f"sum{i}", -10.0 + i, f"snip{i}") for i in range(10)]

# 1. THE rollback guarantee, extended to arm D. W_QVEC=0 must reproduce the
#    pre-arm ordering EXACTLY -- that is what makes the control in every sweep
#    trustworthy, and what makes the arm safe to turn off in an incident.
qrows = [("memory", "n9.md", "a question"), ("memory", "n7.md", "another")]
old_w = fusion.W_QVEC
fusion.W_QVEC = 0.0
off = fusion.fuse(docs, [], [], 5, qvec_rows=qrows)
fusion.W_QVEC = old_w
check("W_QVEC=0 -> arm A order, arm D contributes nothing",
      [d for d, _s, _f in off] == docs[:5])

# 2. An absent arm D must be indistinguishable from the arm never existing.
check("qvec_rows=None is the same as omitting it",
      [d[:2] for d, _, _ in fusion.fuse(docs, [], [], 5, qvec_rows=None)]
      == [d[:2] for d, _, _ in fusion.fuse(docs, [], [], 5)])

# 3. At a live weight the arm must actually move something, or every sweep above
#    was measuring a no-op that happened to look like a plateau.
fusion.W_QVEC = 0.4
on = fusion.fuse(docs, [], [], 5, qvec_rows=qrows)
fusion.W_QVEC = old_w
check("live weight reorders", [d[:2] for d, _, _ in on] != [d[:2] for d in docs[:5]])

# 4. The splitter. agy returns questions run together on one line as often as it
#    returns them one per line, and it emits bare symptom statements with no
#    question mark. Splitting on newlines alone fused five questions into a
#    single 400-char string that embedded to their average and matched none.
blob = ("How do I run X? Where is Y stored?\n"
        "Why\n"
        "Symptom: the thing broke and nothing changed")
parts = qi.split_questions(blob)
check("splits on '?' as well as newline", len(parts) == 3, parts)
check("drops sub-threshold fragments", "Why" not in parts)
check("keeps a question-mark-free symptom line",
      any(p.startswith("Symptom:") for p in parts))
check("empty input is empty, not [''])", qi.split_questions("") == [])

# 5. Deduplication is per DOCUMENT, not per question. Five paraphrases of one
#    question must not occupy five of the slots the arm has to spend.
class _FakeMatrix:
    def __init__(self, hits):
        self._hits = hits

    def knn(self, qvec, k):
        return self._hits[:k]


class _FakeDB:
    def __init__(self, rows):
        self.rows = rows

    def execute(self, sql, params=None):
        # Only the qid-IN branch is exercised here. Returns a cursor-alike so the
        # test exercises the real .fetchall() path rather than a shape that only
        # this fake supports.
        want = set(params or [])
        return _FakeCursor([r for r in self.rows if r[0] in want])


class _FakeCursor(list):
    def fetchall(self):
        return list(self)


rows = [(1, "memory", "a.md", "q1"), (2, "memory", "a.md", "q2"),
        (3, "memory", "a.md", "q3"), (4, "memory", "b.md", "q4")]
got = fusion.question_knn(_FakeDB(rows), [0.0] * 384,
                          matrix=_FakeMatrix([(1, .9), (2, .8), (3, .7), (4, .6)]))
check("one row per document at its best question",
      [(r[0], r[1]) for r in got] == [("memory", "a.md"), ("memory", "b.md")], got)

# 6. The daemon client's arm-D side channel must reset on EVERY call. If it
#    keeps its previous value across an early return, one query's arm D rows
#    rank the next query's results -- silently, and only when the daemon bails.
import daemon_client as dc
dc.last_qrows = [("memory", "stale.md", "from a previous query")]
_enabled = dc.enabled
dc.enabled = False
dc.vector_knn("anything")                      # early return: daemon disabled
dc.enabled = _enabled
check("side channel resets on early return", dc.last_qrows is None, dc.last_qrows)

print("FAILED: " + ", ".join(fails) if fails else "all question-arm checks pass")
sys.exit(1 if fails else 0)
