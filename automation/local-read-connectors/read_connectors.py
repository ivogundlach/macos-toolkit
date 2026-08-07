#!/usr/bin/env python3
import argparse
import json
import sqlite3
import subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import urlparse


HOME = Path.home()
APPLE_EPOCH = 978307200


def connect(path: Path) -> sqlite3.Connection:
    return sqlite3.connect(f"file:{path}?mode=ro", uri=True)


def apple_time_expr(column: str) -> str:
    return f"datetime({column} + {APPLE_EPOCH}, 'unixepoch', 'localtime')"


def print_json(rows):
    print(json.dumps(rows, ensure_ascii=False, indent=2))


def safari_history(args):
    db = HOME / "Library/Safari/History.db"
    cutoff = datetime.now(timezone.utc) - timedelta(days=args.days)
    cutoff_apple = cutoff.timestamp() - APPLE_EPOCH
    query = """
        select i.url, count(v.id) as visits, max(v.visit_time) as last_visit
        from history_items i
        join history_visits v on i.id = v.history_item
        where v.visit_time >= ?
        group by i.url
        order by visits desc
        limit ?
    """
    domains = {}
    with connect(db) as con:
        for url, visits, last_visit in con.execute(query, (cutoff_apple, args.limit)):
            host = urlparse(url).netloc.lower().removeprefix("www.")
            if not host:
                continue
            item = domains.setdefault(host, {"domain": host, "visits": 0, "last_visit": None})
            item["visits"] += visits
            last_dt = datetime.fromtimestamp(last_visit + APPLE_EPOCH).isoformat()
            if item["last_visit"] is None or last_dt > item["last_visit"]:
                item["last_visit"] = last_dt
    print_json(sorted(domains.values(), key=lambda x: x["visits"], reverse=True)[: args.limit])


def screen_time_domains(args):
    db = HOME / "Library/Application Support/Knowledge/knowledgeC.db"
    cutoff_apple = datetime.now(timezone.utc).timestamp() - APPLE_EPOCH - (args.days * 86400)
    query = """
        select m.Z_DKDIGITALHEALTHMETADATAKEY__WEBDOMAIN as domain,
               count(*) as events,
               round(sum(max(0, o.zenddate - o.zstartdate)) / 3600.0, 2) as hours
        from zobject o
        left join zstructuredmetadata m on o.zstructuredmetadata = m.z_pk
        where o.zstartdate >= ?
          and m.Z_DKDIGITALHEALTHMETADATAKEY__WEBDOMAIN is not null
        group by domain
        order by hours desc, events desc
        limit ?
    """
    with connect(db) as con:
        rows = [
            {"domain": d, "events": e, "hours": h}
            for d, e, h in con.execute(query, (cutoff_apple, args.limit))
        ]
    print_json(rows)


def calendar_upcoming(args):
    db = HOME / "Library/Group Containers/group.com.apple.calendar/Calendar.sqlitedb"
    now_apple = datetime.now(timezone.utc).timestamp() - APPLE_EPOCH
    end_apple = now_apple + (args.days * 86400)
    query = f"""
        select ci.summary,
               {apple_time_expr("ci.start_date")} as starts,
               {apple_time_expr("ci.end_date")} as ends,
               c.title as calendar,
               ci.location_id,
               ci.url
        from CalendarItem ci
        left join Calendar c on ci.calendar_id = c.ROWID
        where ci.start_date between ? and ?
          and coalesce(ci.hidden, 0) = 0
        order by ci.start_date asc
        limit ?
    """
    with connect(db) as con:
        rows = [
            {
                "title": title,
                "starts": starts,
                "ends": ends,
                "calendar": cal,
                "url": url,
            }
            for title, starts, ends, cal, _location_id, url in con.execute(
                query, (now_apple, end_apple, args.limit)
            )
        ]
    print_json(rows)


def reminders_open(args):
    root = HOME / "Library/Group Containers/group.com.apple.reminders/Container_v1/Stores"
    rows = []
    for db in sorted(root.glob("Data-*.sqlite")):
        with connect(db) as con:
            count = con.execute("select count(*) from ZREMCDREMINDER").fetchone()[0]
            if not count:
                continue
            query = f"""
                select r.ZTITLE,
                       l.ZNAME,
                       r.ZCOMPLETED,
                       {apple_time_expr("r.ZDUEDATE")} as due_date,
                       {apple_time_expr("r.ZDISPLAYDATEDATE")} as display_date,
                       r.ZPRIORITY,
                       r.ZNOTES
                from ZREMCDREMINDER r
                left join ZREMCDBASELIST l on r.ZLIST = l.Z_PK
                where coalesce(r.ZCOMPLETED, 0) = 0
                  and coalesce(r.ZMARKEDFORDELETION, 0) = 0
                order by coalesce(r.ZDUEDATE, r.ZDISPLAYDATEDATE, 9999999999) asc
                limit ?
            """
            rows.extend(
                {
                    "title": title,
                    "list": list_name,
                    "due_date": due_date,
                    "display_date": display_date,
                    "priority": priority,
                    "has_notes": bool(notes),
                }
                for title, list_name, _completed, due_date, display_date, priority, notes
                in con.execute(query, (args.limit,))
            )
    print_json(rows[: args.limit])


def mail_summary(args):
    db = HOME / "Library/Mail/V10/MailData/Envelope Index"
    query = """
        select count(*) as mailbox_count,
               sum(total_count) as total_messages,
               sum(unread_count) as unread_messages,
               sum(deleted_count) as deleted_messages
        from mailboxes
    """
    with connect(db) as con:
        mailbox_count, total, unread, deleted = con.execute(query).fetchone()
    print_json(
        {
            "mailbox_count": mailbox_count,
            "total_messages": total,
            "unread_messages": unread,
            "deleted_messages": deleted,
        }
    )


def mail_search(args):
    db = HOME / "Library/Mail/V10/MailData/Envelope Index"
    terms = [t.strip().lower() for t in args.query.split() if t.strip()]
    if not terms:
        raise SystemExit("mail-search requires a non-empty query")
    days_cutoff = int((datetime.now(timezone.utc) - timedelta(days=args.days)).timestamp())
    clauses = []
    params = [days_cutoff]
    # Match the sender, the subject, AND the recipients. Recipients matter because
    # mail Ivo SENT to someone carries that person only in the recipients table --
    # a sender+subject-only search returns [] for a correspondent he has written to
    # for years, and an empty result then reads as "no correspondence exists".
    for term in terms:
        like = f"%{term}%"
        clauses.append(
            "("
            "lower(coalesce(s.subject, '')) like ?"
            " or lower(coalesce(a.address, '')) like ?"
            " or lower(coalesce(a.comment, '')) like ?"
            " or exists ("
            "   select 1 from recipients r"
            "   join addresses ra on r.address = ra.ROWID"
            "   where r.message = m.ROWID"
            "     and (lower(coalesce(ra.address, '')) like ?"
            "          or lower(coalesce(ra.comment, '')) like ?)"
            " )"
            ")"
        )
        params.extend([like, like, like, like, like])
    params.append(args.limit)
    query = f"""
        select m.ROWID,
               a.address,
               a.comment,
               s.subject,
               datetime(m.date_received, 'unixepoch', 'localtime') as received,
               mb.url,
               m.read,
               m.flagged,
               (select group_concat(ra.address, ', ')
                  from recipients r
                  join addresses ra on r.address = ra.ROWID
                 where r.message = m.ROWID) as recipients
        from messages m
        left join addresses a on m.sender = a.ROWID
        left join subjects s on m.subject = s.ROWID
        left join mailboxes mb on m.mailbox = mb.ROWID
        where m.date_received >= ?
          and ({" and ".join(clauses)})
        order by m.date_received desc
        limit ?
    """
    with connect(db) as con:
        rows = [
            {
                "mail_rowid": rowid,
                "from": address,
                "from_name": comment,
                "to": recipients,
                "subject": subject,
                "received": received,
                "mailbox": mailbox,
                "read": bool(read),
                "flagged": bool(flagged),
            }
            for rowid, address, comment, subject, received, mailbox, read, flagged, recipients
            in con.execute(query, params)
        ]
    print_json(rows)


def notes(args):
    bin_path = HOME / ".local/share/codex-connectors/venv/bin/apple-notes-parser"
    db = HOME / "Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"
    command = [str(bin_path), "--database", str(db)]
    if args.query:
        command += ["search", args.query]
    else:
        command += ["stats"]
    subprocess.run(command, check=True)


def youtube(args):
    command = [
        "/opt/homebrew/bin/yt-dlp",
        "--dump-json",
        "--skip-download",
        "--no-warnings",
        args.url,
    ]
    proc = subprocess.run(command, check=True, capture_output=True, text=True)
    data = json.loads(proc.stdout.splitlines()[0])
    keep = {
        "id": data.get("id"),
        "title": data.get("title"),
        "channel": data.get("channel"),
        "channel_url": data.get("channel_url"),
        "duration": data.get("duration"),
        "view_count": data.get("view_count"),
        "upload_date": data.get("upload_date"),
        "webpage_url": data.get("webpage_url"),
        "description": data.get("description"),
    }
    print_json(keep)


def main():
    parser = argparse.ArgumentParser(description="Read-only local connectors for Codex.")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("safari-history")
    p.add_argument("--days", type=int, default=30)
    p.add_argument("--limit", type=int, default=25)
    p.set_defaults(func=safari_history)

    p = sub.add_parser("screen-time-domains")
    p.add_argument("--days", type=int, default=30)
    p.add_argument("--limit", type=int, default=25)
    p.set_defaults(func=screen_time_domains)

    p = sub.add_parser("calendar-upcoming")
    p.add_argument("--days", type=int, default=14)
    p.add_argument("--limit", type=int, default=25)
    p.set_defaults(func=calendar_upcoming)

    p = sub.add_parser("reminders-open")
    p.add_argument("--limit", type=int, default=50)
    p.set_defaults(func=reminders_open)

    p = sub.add_parser("mail-summary")
    p.set_defaults(func=mail_summary)

    p = sub.add_parser("mail-search")
    p.add_argument("query")
    p.add_argument("--days", type=int, default=90)
    p.add_argument("--limit", type=int, default=20)
    p.set_defaults(func=mail_search)

    p = sub.add_parser("notes")
    p.add_argument("query", nargs="?")
    p.set_defaults(func=notes)

    p = sub.add_parser("youtube")
    p.add_argument("url")
    p.set_defaults(func=youtube)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
