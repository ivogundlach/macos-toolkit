import sys, os, re, random
sys.path.insert(0, os.path.expanduser("~/.memory/tools"))
from pathlib import Path
from chunker import chunk_file, chunk_text
from file_eligibility import iter_files, read_text
from index_scope import load_root_excludes

fails = []

def check(name, cond, detail=""):
    print(("  ok  " if cond else "  FAIL") + f" {name} {detail}")
    if not cond: fails.append(name)

print("== unit ==")
check("empty", chunk_text("") == [])
check("whitespace only", chunk_text("   \n\n  ") == [])
a = chunk_text("# A\n\nbody one\n\n## B\n\nbody two", "x.md")
check("headings become breadcrumbs", any("A > B" in c["heading"] for c in a), [c["heading"] for c in a])
fenced = "# T\n\n```sh\n# not a heading\necho hi\n```\n\ntail"
check("fence protects # lines", len({c["heading"] for c in chunk_text(fenced, "x.md")}) == 1,
      {c["heading"] for c in chunk_text(fenced, "x.md")})
long_line = "x" * 300_000
cs, ov = chunk_file(long_line, "big.json")
check("one 300k line is split", len(cs) > 1 and all(len(c["text"]) <= 3000 for c in cs), f"{len(cs)} chunks")
check("no chunk exceeds ceiling", all(len(c["text"]) <= 3200 for c in cs))
check("determinism", chunk_text(long_line, "big.json") == chunk_text(long_line, "big.json"))
check("crlf normalised", chunk_text("a\r\n\r\nb", "x.md") == chunk_text("a\n\nb", "x.md"))

print("\n== content preservation over the real corpus ==")
roots = [Path(os.path.expanduser(l.strip())) for l in
         open(os.path.expanduser("~/.memory/semantic-folders.txt"))
         if l.strip() and not l.strip().startswith("#")]
files = []
for r in roots:
    if r.is_dir():
        files += list(iter_files(r, load_root_excludes(r)))
random.seed(11)
sample = random.sample(files, min(400, len(files)))
lost, checked, maxchunks, overflows, total_chunks = [], 0, 0, 0, 0
for p in sample:
    t = read_text(p)
    if not t.strip(): continue
    cs, ov = chunk_file(t, str(p))
    overflows += 1 if ov else 0
    total_chunks += len(cs)
    maxchunks = max(maxchunks, len(cs))
    joined = "".join(c["text"] for c in cs)
    # every non-whitespace char of the source must appear in the chunk set
    src = re.sub(r"\s+", "", t)
    dst = re.sub(r"\s+", "", joined)
    checked += 1
    if len(src) > 0:
        # subsequence check is O(n); chunks are ordered so source order is preserved
        i = 0
        for ch in dst:
            if i < len(src) and ch == src[i]: i += 1
        if i < len(src):
            lost.append((str(p), len(src), i))
check(f"no content lost across {checked} real files", not lost, lost[:3])
check("no file overflowed the chunk cap", overflows == 0, f"overflows={overflows} maxchunks={maxchunks}")
print(f"  info: {total_chunks} chunks from {checked} files (mean {total_chunks/max(checked,1):.1f}/file)")

print("\n== the previously-truncated high-value files ==")
for name in ["wiki/preferences.md", "wiki/workflows.md", "current.md"]:
    p = Path(os.path.expanduser("~/.memory")) / name
    if p.exists():
        t = read_text(p); cs, ov = chunk_file(t, name)
        covered = len(t) <= sum(len(c["text"]) for c in cs)
        print(f"  {name}: {len(t)} chars (was truncated at 20000) -> {len(cs)} chunks, full coverage={covered}")
        if len(t) > 20000: check(f"{name} beyond 20k now indexed", cs and covered)

print("\nRESULT:", "ALL PASS" if not fails else f"FAILURES: {fails}")
sys.exit(1 if fails else 0)
