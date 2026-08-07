import sys, os
sys.path.insert(0, os.path.expanduser("~/.memory/tools"))
import fusion
fails=[]
def check(n,c,d=""):
    print(("  ok  " if c else "  FAIL")+f" {n} {d}")
    if not c: fails.append(n)

docs = [("memory", f"n{i}.md", f"sum{i}", -10.0+i, f"snip{i}") for i in range(10)]

# 1. THE rollback guarantee
out = fusion.fuse(docs, [], [], 5)
check("both new arms absent -> arm A order, unchanged",
      [d for d,_s,_f in out] == docs[:5])

# 2. determinism incl. ties
c1 = [("memory","n9.md","x"), ("memory","n8.md","y")]
v1 = [("memory","n8.md","z"), ("memory","n9.md","w")]
r1 = fusion.fuse(docs, c1, v1, 8)
r2 = fusion.fuse(docs, list(c1), list(v1), 8)
check("deterministic across calls", [d[:2] for d,_,_ in r1] == [d[:2] for d,_,_ in r2])

# 3. per-file cap stops one big file crowding the pool
big = [("Projects", "huge.md", f"c{i}") for i in range(50)]
capped = fusion._cap_per_file(big)
check("per-file chunk cap", len(capped) == fusion.MAX_CHUNKS_PER_FILE, f"{len(capped)}")
mixed = [("P","a.md","1"),("P","a.md","2"),("P","a.md","3"),("P","a.md","4"),("P","b.md","1")]
cm = fusion._cap_per_file(mixed)
check("cap preserves order and other files", cm[-1] == ("P","b.md","1") and len(cm)==4, cm)

# 4. a file only the vector arm knows still surfaces
only_vec = [("Files","secret-doc.md","body text")]
r = fusion.fuse(docs, [], only_vec, 12)
check("vector-only file surfaces", any(d[1]=="secret-doc.md" for d,_,_ in r))

# 5. curated prior nudges but does not filter
fusion.SOURCE_PRIOR = 0.10
cur = fusion._is_curated("memory","note.md")
raw = fusion._is_curated(".memory","raw/chat/x.md")
wiki = fusion._is_curated(".memory","wiki/preferences.md")
check("curated classification", cur and wiki and not raw, f"cur={cur} wiki={wiki} raw={raw}")

# 6. arm with fewer results than depth does not error
check("short arms fine", len(fusion.fuse(docs[:2], [("memory","n0.md","s")], [], 5)) >= 1)

# 7. RERANK CONTRACT. The reranker may only REORDER: same members, same count,
# every time. A reranker that can drop a candidate is a reranker that can lose
# the answer, which is strictly worse than not having one.
keys = [("memory", f"n{i}.md") for i in range(6)]
scored = {k: float(len(keys) - i) for i, k in enumerate(keys)}
out = fusion.rerank_fuse(keys, scored)
check("rerank preserves membership", sorted(out) == sorted(keys) and len(out) == len(keys))

# 8. FAIL-OPEN. No scores, or too few to compare, leaves the order untouched.
check("no scores -> unchanged", fusion.rerank_fuse(keys, {}) == keys)
check("one score -> unchanged", fusion.rerank_fuse(keys, {keys[3]: 9.0}) == keys)

# 9. PARTIAL scores must not scramble: unscored candidates keep their relative
# order and stay behind the scored block rather than being reshuffled.
part = fusion.rerank_fuse(keys, {keys[4]: 9.0, keys[0]: -9.0})
check("partial keeps unscored order",
      [k for k in part if k not in (keys[0], keys[4])] == [keys[1], keys[2], keys[3], keys[5]],
      str(part))

# 10. It reorders on a SINGULAR disagreement, and is deliberately deaf to a
# uniform one. A straight reversal moves nothing: every item shifts by the same
# number of cross-encoder positions, so no pair's gap ever closes. Only a
# candidate the reranker singles out climbs. That conservatism is the reason the
# reranker gained 7.7 points at recall@1 without regressing a single gold case
# -- it can settle a near-miss, it cannot drag rank 10 to rank 1.
k10 = [("memory", f"m{i}.md") for i in range(10)]
rev = fusion.rerank_fuse(k10, {k: float(len(k10) - i) for i, k in enumerate(k10)})
check("uniform reversal changes nothing", rev == k10)

singled = {k: 1.0 for k in k10}
singled[k10[5]] = 99.0                      # the reranker's clear favourite
promoted = fusion.rerank_fuse(k10, singled)
check("singled-out candidate climbs",
      promoted.index(k10[5]) < 5 and sorted(promoted) == sorted(k10),
      f"5 -> {promoted.index(k10[5])}")

# 11. DETERMINISM under tied cross-encoder scores.
tied = {k: 1.0 for k in keys}
check("tied scores deterministic",
      fusion.rerank_fuse(keys, tied) == fusion.rerank_fuse(keys, dict(tied)))

print("\nRESULT:", "ALL PASS" if not fails else f"FAILURES: {fails}")
sys.exit(1 if fails else 0)
