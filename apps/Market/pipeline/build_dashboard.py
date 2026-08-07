"""RETIRED 2026-07-01: email delivery removed (Ivo) — the app is the sole notification + debrief surface. Kept only as reference; no pipeline caller remains.

Render the Live-Database HTML dashboard from the canonical store + a debrief dict.

Design: light "Live Database" house style, information-dense, empty sections collapsed.
Security: every external string is HTML-escaped; links render only for allowlisted hosts
with rel=noopener; restrictive CSP meta. Fails loudly if the output dir does not exist.
"""
import html
import json
import os
import sys
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import store
import util

DIR_COLOR = {"bullish": "pos", "bearish": "neg"}


def esc(s):
    return html.escape(str(s if s is not None else ""), quote=True)


def rank_labels(cfg):
    """rank int -> human label, e.g. 3 -> 'X · tier 1'."""
    names = {0: "Market data", 1: "Discord alerts", 2: "TradingView",
             3: "X · tier 1", 4: "YouTube", 5: "X · tier 2"}
    return names


def pretty_source(origin, cfg):
    """'youtube:UC...' -> 'YouTube · ZipTrader'; 'x_tier1:wliang' -> '@wliang'."""
    src, _, who = origin.partition(":")
    if src.startswith("x_"):
        return "@" + who
    if src == "youtube":
        nm = cfg["sources"]["youtube"].get("channel_names", {}).get(who, who)
        return f"YouTube · {nm}"
    if src == "tradingview":
        return "TradingView"
    if src == "discord":
        return "Discord"
    return origin


def pretty_author(source, author, cfg):
    if source == "youtube":
        return cfg["sources"]["youtube"].get("channel_names", {}).get(author, author)
    if source.startswith("x_"):
        return "@" + author
    return author


def safe_links(urls_json, cfg, label="open"):
    hosts = set(cfg["url_allowlist_hosts"])
    out = []
    for u in json.loads(urls_json or "[]"):
        if util.allowed_url(u, hosts):
            out.append(f'<a href="{esc(u)}" target="_blank" rel="noopener noreferrer">{esc(label)}</a>')
    return " ".join(out)


def bar(pct, cls=""):
    p = max(0, min(100, pct))
    return f'<span class="cbar {cls}"><i style="width:{p:.0f}%"></i></span>'


def regime_card(regime):
    if not regime:
        return '<section class="card"><h2>Market regime</h2><p class="muted">No regime snapshot.</p></section>'
    vix, trend, fg, pc, oi, score, conf = regime
    if score is None:
        cls, label = "neu", "no score"
    else:
        cls = "pos" if score >= 60 else ("neg" if score < 40 else "neu")
        label = "Bullish" if score >= 60 else ("Bearish" if score < 40 else "Neutral")
    scoretxt = f"{score:.0f}" if score is not None else "—"
    trendtxt = f"{trend:+.2f}" if isinstance(trend, (int, float)) else "—"
    return f"""<section class="card regime">
<h2>Market regime <span class="pill {cls}">{esc(label)}</span></h2>
<div class="regwrap">
  <div class="score {cls}">{esc(scoretxt)}<small>/100</small></div>
  <div class="regbar">{bar(score or 0, cls)}</div>
</div>
<div class="stats">
  <span><b>VIX</b> {esc(vix)} <em>({esc(trendtxt)} 5d)</em></span>
  <span><b>Fear/Greed</b> {esc(fg)}</span>
  <span><b>Put/Call</b> {esc(pc)}</span>
  <span><b>Confidence</b> {esc(conf)}</span>
</div></section>"""


def debrief_card(debrief, degraded, labels):
    by_rank = [b for b in debrief.get("by_rank", []) if str(b.get("summary", "")).strip()]
    rows = "".join(
        f'<div class="rrow"><span class="rtag">{esc(labels.get(b["rank"], "Rank "+str(b["rank"])))}</span>'
        f'<p>{esc(b["summary"])}</p></div>' for b in by_rank)
    watch = esc(debrief.get("watch_notes", ""))
    watch_html = f'<div class="rrow"><span class="rtag warn">Watch</span><p>{watch}</p></div>' if watch.strip() else ""
    cls = " degraded" if degraded else ""
    return f"""<section class="card debrief{cls}">
<h2>Debrief{' · DEGRADED' if degraded else ''}</h2>
<p class="headline">{esc(debrief.get('headline'))}</p>
<p class="summary">{esc(debrief.get('market_summary'))}</p>
{rows}{watch_html}</section>"""


def signals_table(con, session_date, cfg, labels):
    rows = con.execute(
        "SELECT ticker, direction, strength, best_rank, origin_key, track_proposal, event_ids "
        "FROM signals WHERE session_date=? ORDER BY best_rank, ticker", (session_date,)).fetchall()
    if not rows:
        return ""
    trs = []
    for tk, d, st, rk, ok, tp, eids in rows:
        srcs = ", ".join(esc(pretty_source(o, cfg)) for o in ok.split("|"))
        trs.append(
            f"<tr><td class='tk'>{esc(tk)}</td>"
            f"<td class='{DIR_COLOR.get(d,'')}'>{esc(d)}</td><td>{esc(st)}</td>"
            f"<td>{esc(tp)}</td><td class='num'>{len(ok.split('|'))}</td>"
            f"<td class='src'>{srcs}</td></tr>")
    return f"""<section class="card"><h2>Today's signals <small>({len(rows)})</small></h2>
<table class="dense"><thead><tr><th>Ticker</th><th>Dir</th><th>Strength</th>
<th>Track</th><th>Voices</th><th>Sources</th></tr></thead><tbody>{''.join(trs)}</tbody></table></section>"""


def track_tables(con, cfg):
    blocks = []
    for track in ("growth", "value", "dividends"):
        rows = con.execute(
            "SELECT ticker, conviction, status, entered_at, last_signal_at FROM tracks "
            "WHERE track=? AND status IN ('active','conflict') ORDER BY conviction DESC", (track,)).fetchall()
        if not rows:
            body = '<p class="muted">—</p>'
        else:
            trs = "".join(
                f"<tr><td class='tk'>{esc(t)}</td><td class='num'>{c:.0f}{bar(c)}</td>"
                f"<td class='{'warn' if s=='conflict' else 'ok'}'>{esc(s)}</td>"
                f"<td class='dt'>{esc((e or '')[:10])}</td></tr>"
                for t, c, s, e, ls in rows)
            body = (f"<table class='dense'><thead><tr><th>Ticker</th><th>Conviction</th>"
                    f"<th>Status</th><th>In</th></tr></thead><tbody>{trs}</tbody></table>")
        blocks.append(f"<div class='trk'><h3>{track.title()}</h3>{body}</div>")
    return f'<section class="card"><h2>Recommendation tracks</h2><div class="trkgrid">{"".join(blocks)}</div></section>'


def watchlist_block(con, cfg):
    if not cfg["delivery"].get("show_positions", True):
        return ""
    if not table_exists(con, "watchlists"):
        return '<section class="card"><h2>Watchlists &amp; positions</h2><p class="muted">No snapshot yet (TradingView scrape pending).</p></section>'
    rows = con.execute("SELECT name, kind, tickers, scraped_at, stale FROM watchlists ORDER BY kind, name").fetchall()
    if not rows:
        return '<section class="card"><h2>Watchlists &amp; positions</h2><p class="muted">No snapshot yet.</p></section>'
    blocks = []
    for name, kind, tickers, scraped_at, stale in rows:
        warn = " <span class='warn'>STALE</span>" if stale else ""
        tks = ", ".join(esc(t) for t in json.loads(tickers or "[]"))
        blocks.append(f"<div class='wl'><h4>{esc(name)} <small>({esc(kind)}){warn}</small></h4>"
                      f"<p>{tks or '—'}</p></div>")
    return f'<section class="card"><h2>Watchlists &amp; positions</h2>{"".join(blocks)}</section>'


def table_exists(con, name):
    return con.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)).fetchone() is not None


def source_feed(con, cfg, labels, limit=60):
    rows = con.execute(
        "SELECT rank, source, author, ts, text, urls FROM events WHERE source!='regime' "
        "ORDER BY ts DESC LIMIT ?", (limit,)).fetchall()
    by_rank = {}
    for rank, source, author, ts, text, urls in rows:
        by_rank.setdefault(rank, []).append(
            f"<li><span class='meta'>{esc(pretty_author(source,author,cfg))} · {esc(ts[:16].replace('T',' '))} {safe_links(urls,cfg)}</span>"
            f"<span class='txt'>{esc(text[:240])}{'…' if len(text)>240 else ''}</span></li>")
    out = []
    for rank in sorted(by_rank):
        out.append(f"<h3>{esc(labels.get(rank,'Rank '+str(rank)))} <small>({len(by_rank[rank])})</small></h3>"
                   f"<ul class='feed'>{''.join(by_rank[rank])}</ul>")
    if not out:
        return ""
    return f'<section class="card"><h2>Source feed</h2>{"".join(out)}</section>'


def health_footer(con, cfg, labels):
    cells = []
    for src, sc in cfg["sources"].items():
        row = con.execute("SELECT MAX(ingested_at) FROM events WHERE source=?", (src,)).fetchone()
        last = (row[0][:10] if row and row[0] else ("off" if not sc.get("enabled") else "never"))
        cells.append(f"{esc(src)} {esc(last)}")
    return " · ".join(cells)


def render(con, cfg, debrief, regime, meta, session_label, session_date):
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    labels = rank_labels(cfg)
    degraded = meta.get("degraded", False)
    return f"""<!doctype html><html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:;">
<title>Market Live Database</title>
<style>
:root{{--page:#f4f6f9;--card:#fff;--ink:#15212e;--body:#33424f;--muted:#75828f;
--line:#e1e7ee;--line2:#cfd8e2;--blue:#1858b8;--pos:#0a7f55;--neg:#c0392b;--warn:#b3690a;--accent:#1858b8;}}
*{{box-sizing:border-box}}body{{margin:0;background:var(--page);color:var(--body);
font:13.5px/1.5 Inter,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}}
.shell{{max-width:980px;margin:0 auto;padding:20px 16px 50px}}
h1{{font-size:1.35rem;color:var(--ink);margin:0}}.subline{{color:var(--muted);font-size:.8rem;margin:2px 0 14px}}
.card{{background:var(--card);border:1px solid var(--line);border-radius:9px;padding:13px 15px;margin:11px 0;box-shadow:0 1px 2px rgba(20,33,46,.04)}}
h2{{font-size:.78rem;text-transform:uppercase;letter-spacing:.05em;color:var(--muted);margin:0 0 9px;border-bottom:1px solid var(--line);padding-bottom:6px}}
h2 small{{text-transform:none;letter-spacing:0}}
h3{{font-size:.8rem;color:var(--ink);margin:11px 0 5px}}h4{{margin:0 0 3px;font-size:.85rem;color:var(--ink)}}
.muted{{color:var(--muted)}}.pos{{color:var(--pos)}}.neg{{color:var(--neg)}}.warn{{color:var(--warn)}}.ok{{color:var(--pos)}}
.pill{{font-size:.62rem;font-weight:700;padding:2px 7px;border-radius:99px;vertical-align:middle;text-transform:uppercase}}
.pill.pos{{background:#e3f4ec;color:var(--pos)}}.pill.neg{{background:#fbe9e7;color:var(--neg)}}.pill.neu{{background:#fdf1df;color:var(--warn)}}
.regwrap{{display:flex;align-items:center;gap:14px}}.score{{font-size:2.3rem;font-weight:800;line-height:1}}.score small{{font-size:.9rem;color:var(--muted);font-weight:500}}
.score.pos{{color:var(--pos)}}.score.neg{{color:var(--neg)}}.score.neu{{color:var(--warn)}}
.regbar{{flex:1}}.cbar{{display:inline-block;width:100%;height:7px;background:#eef2f6;border-radius:4px;overflow:hidden;vertical-align:middle}}
.cbar i{{display:block;height:100%;background:var(--accent)}}.cbar.pos i{{background:var(--pos)}}.cbar.neg i{{background:var(--neg)}}.cbar.neu i{{background:var(--warn)}}
td .cbar{{width:46px;margin-left:6px}}
.stats{{display:flex;flex-wrap:wrap;gap:6px 20px;margin-top:10px;font-size:.85rem}}.stats b{{color:var(--ink)}}.stats em{{color:var(--muted);font-style:normal}}
.headline{{font-size:1.02rem;font-weight:700;color:var(--ink);margin:0 0 7px}}.summary{{margin:0 0 10px;white-space:pre-wrap}}
.rrow{{display:flex;gap:10px;padding:6px 0;border-top:1px solid var(--line)}}.rrow p{{margin:0}}
.rtag{{flex:0 0 96px;font-size:.7rem;font-weight:700;color:var(--blue);text-transform:uppercase;letter-spacing:.03em;padding-top:1px}}.rtag.warn{{color:var(--warn)}}
table.dense{{width:100%;border-collapse:collapse;font-size:.83rem}}
table.dense th{{text-align:left;color:var(--muted);font-weight:600;padding:4px 7px;border-bottom:1px solid var(--line2);font-size:.72rem;text-transform:uppercase;letter-spacing:.03em}}
table.dense td{{padding:4px 7px;border-bottom:1px solid var(--line)}}.dense .tk{{font-weight:700;color:var(--ink)}}.dense .num{{white-space:nowrap}}.dense .src{{color:var(--muted);font-size:.78rem}}.dense .dt{{color:var(--muted);font-size:.78rem}}
.trkgrid{{display:grid;grid-template-columns:1fr 1fr 1fr;gap:14px}}@media(max-width:720px){{.trkgrid{{grid-template-columns:1fr}}}}
.wl{{display:inline-block;vertical-align:top;margin:0 22px 10px 0}}.wl p{{margin:1px 0 0;font-size:.85rem}}
.feed{{list-style:none;padding:0;margin:0 0 4px}}.feed li{{padding:5px 0;border-top:1px solid var(--line)}}
.feed .meta{{display:block;color:var(--muted);font-size:.72rem;margin-bottom:1px}}.feed .meta a{{color:var(--blue)}}.feed .txt{{font-size:.83rem}}
.degraded{{border-color:var(--neg)}}.degraded h2{{color:var(--neg)}}
footer{{color:var(--muted);font-size:.7rem;margin-top:16px;line-height:1.7}}footer b{{color:var(--body)}}
</style></head><body><div class="shell">
<h1>Market Live Database</h1>
<p class="subline">{esc(session_label)} · generated {esc(now)}{' · DEGRADED RUN' if degraded else ''}</p>
{regime_card(regime)}
{debrief_card(debrief, degraded, labels)}
{signals_table(con, session_date, cfg, labels)}
{track_tables(con, cfg)}
{watchlist_block(con, cfg)}
{source_feed(con, cfg, labels)}
<footer><b>Adapter health</b> — {health_footer(con, cfg, labels)}<br>
Decision support only · not financial advice · no trades are placed by this system.</footer>
</div></body></html>"""


def render_email(con, cfg, debrief, meta, session_label, session_date=None):
    """Render the debrief HTML for the EMAIL BODY only — no file is written.

    The native Market app replaced the standalone Live-Database HTML dashboard (Ivo 2026-06-14);
    build_dashboard is now an email-body renderer. The full self-contained HTML doc that render()
    produces is reused verbatim as the email's HTML alternative part.
    """
    from datetime import date
    session_date = session_date or date.today().isoformat()
    regime = con.execute(
        "SELECT vix, vix_trend5d, fear_greed, put_call, oi_note, score, confidence FROM regime "
        "ORDER BY session_date DESC LIMIT 1").fetchone()
    html_doc = render(con, cfg, debrief, regime, meta, session_label, session_date)
    util.log("build_dashboard", f"rendered email body ({len(html_doc)} bytes, no file written)")
    return html_doc
