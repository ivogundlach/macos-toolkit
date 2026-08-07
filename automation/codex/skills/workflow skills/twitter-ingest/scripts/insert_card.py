#!/usr/bin/env python3
"""Insert a source-card into the Twitter Bookmarks Archive, in place.

Usage:
  insert_card.py --list-sections
  insert_card.py --section race --card-file /path/to/card.html [--archive PATH]

The card file contains one complete <article class="source-card">...</article>
block. The script appends it at the end of the section's .source-list, bumps
the section's "N sources" count and the nav count, and rewrites the file
atomically. Stdlib only; idempotent per unique source-link URL (refuses to
insert a card whose href already exists in the archive).
"""

import argparse
import json
import os
import re
import sys
import tempfile

CONFIG = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                      "config", "defaults.json")


def default_archive() -> str:
    with open(CONFIG) as fh:
        return json.load(fh)["archive_path"]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--archive", default=None)
    ap.add_argument("--section", help="section id, e.g. race, immigration, iq")
    ap.add_argument("--card-file", help="file holding the <article> block to insert")
    ap.add_argument("--list-sections", action="store_true")
    args = ap.parse_args()

    archive = args.archive or default_archive()
    with open(archive, encoding="utf-8", errors="replace") as fh:
        html = fh.read()

    sections = re.findall(r'<section id="([^"]+)">', html)
    if args.list_sections:
        for s in sections:
            print(s)
        return 0

    if not args.section or not args.card_file:
        ap.error("--section and --card-file are required unless --list-sections")
    if args.section not in sections:
        print(f"Unknown section '{args.section}'. Known: {', '.join(sections)}", file=sys.stderr)
        return 2

    with open(args.card_file, encoding="utf-8") as fh:
        card = fh.read().strip()
    if '<article class="source-card"' not in card or not card.endswith("</article>"):
        print("Card file must be one complete <article class=\"source-card\">...</article> block.", file=sys.stderr)
        return 2

    hrefs = re.findall(r'class="source-link" href="([^"]+)"', card)
    for href in hrefs:
        if href in html:
            print(f"Already ingested: {href} exists in the archive. Nothing done.", file=sys.stderr)
            return 3

    # Locate the section block and its closing </section>.
    start = html.index(f'<section id="{args.section}">')
    end = html.index("</section>", start)
    block = html[start:end]

    # Insert before the final </div> that closes .source-list.
    close = block.rfind("</div>")
    if close < 0:
        print("Could not find .source-list closing tag in section.", file=sys.stderr)
        return 4
    new_block = block[:close] + card + "\n                " + block[close:]

    # Bump "N sources" in the section header.
    def bump(m):
        return f"{int(m.group(1)) + 1} source"
    new_block = re.sub(r"(\d+) source", bump, new_block, count=1)

    html = html[:start] + new_block + html[end:]

    # Bump the nav count for this section: <a href="#id">Name <span>N</span></a>
    nav_re = re.compile(r'(<a href="#%s">[^<]*<span>)(\d+)(</span>)' % re.escape(args.section))
    html = nav_re.sub(lambda m: m.group(1) + str(int(m.group(2)) + 1) + m.group(3), html, count=1)

    tmp = tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False,
                                      dir=os.path.dirname(archive))
    try:
        tmp.write(html)
        tmp.close()
        os.replace(tmp.name, archive)
    except BaseException:
        os.unlink(tmp.name)
        raise
    print(f"Inserted card into '{args.section}' ({archive}).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
