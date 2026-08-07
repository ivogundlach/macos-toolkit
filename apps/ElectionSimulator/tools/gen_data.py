#!/usr/bin/env python3
# gen_data.py — build the embedded dataset for Psephos (Election Simulator).
#
# Fuses REAL fetched data (data/census_seed.json, data/senate_seed.json — see tools/fetch.sh)
# with cited national demographic + electoral tables, and emits:
#   - Resources/dataset.json          (human-readable, the source of truth on disk)
#   - Sources/GeneratedData.swift     (same JSON embedded as a Swift string literal)
#
# Idempotent: re-run any time the seeds or tables change. Standard library only.
import json, pathlib, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DATA = ROOT / "data"

# ---------------------------------------------------------------------------
# State postal codes + names (50 states + DC)
# ---------------------------------------------------------------------------
POSTAL = {
 "Alabama":"AL","Alaska":"AK","Arizona":"AZ","Arkansas":"AR","California":"CA",
 "Colorado":"CO","Connecticut":"CT","Delaware":"DE","Florida":"FL","Georgia":"GA",
 "Hawaii":"HI","Idaho":"ID","Illinois":"IL","Indiana":"IN","Iowa":"IA","Kansas":"KS",
 "Kentucky":"KY","Louisiana":"LA","Maine":"ME","Maryland":"MD","Massachusetts":"MA",
 "Michigan":"MI","Minnesota":"MN","Mississippi":"MS","Missouri":"MO","Montana":"MT",
 "Nebraska":"NE","Nevada":"NV","New Hampshire":"NH","New Jersey":"NJ","New Mexico":"NM",
 "New York":"NY","North Carolina":"NC","North Dakota":"ND","Ohio":"OH","Oklahoma":"OK",
 "Oregon":"OR","Pennsylvania":"PA","Rhode Island":"RI","South Carolina":"SC",
 "South Dakota":"SD","Tennessee":"TN","Texas":"TX","Utah":"UT","Vermont":"VT",
 "Virginia":"VA","Washington":"WA","West Virginia":"WV","Wisconsin":"WI","Wyoming":"WY",
}

# Square-tile cartogram coordinates (col,row) — recognizable US layout, no geometry needed.
TILE = {
 "AK":(0,0),"ME":(11,0),
 "VT":(10,1),"NH":(11,1),
 "WA":(1,2),"ID":(2,2),"MT":(3,2),"ND":(4,2),"MN":(5,2),"IL":(6,2),"WI":(7,2),"MI":(8,2),"NY":(9,2),"RI":(10,2),"MA":(11,2),
 "OR":(1,3),"NV":(2,3),"WY":(3,3),"SD":(4,3),"IA":(5,3),"IN":(6,3),"OH":(7,3),"PA":(8,3),"NJ":(9,3),"CT":(10,3),
 "CA":(1,4),"UT":(2,4),"CO":(3,4),"NE":(4,4),"MO":(5,4),"KY":(6,4),"WV":(7,4),"VA":(8,4),"MD":(9,4),"DE":(10,4),
 "AZ":(2,5),"NM":(3,5),"KS":(4,5),"AR":(5,5),"TN":(6,5),"NC":(7,5),"SC":(8,5),"DC":(9,5),
 "OK":(4,6),"LA":(5,6),"MS":(6,6),"AL":(7,6),"GA":(8,6),
 "HI":(1,7),"TX":(4,7),"FL":(9,7),
}

# ---------------------------------------------------------------------------
# REAL: 2024 presidential two-party Democratic share by state (%) — baseline lean.
# Source: 2024 certified results (AP / Cook Political Report), two-party (D/(D+R)).
# Approximate to ~0.5pt; used as the partisan-lean proxy for races. As of: 2024 general.
# ---------------------------------------------------------------------------
PRES2024_DEM2P = {
 "AL":35.0,"AK":43.0,"AZ":47.2,"AR":34.0,"CA":60.0,"CO":55.0,"CT":56.5,"DE":56.5,
 "DC":92.5,"FL":43.4,"GA":48.9,"HI":61.0,"ID":31.0,"IL":55.0,"IN":40.5,"IA":44.0,
 "KS":41.5,"KY":34.0,"LA":39.0,"ME":53.5,"MD":63.0,"MA":62.0,"MI":49.3,"MN":52.0,
 "MS":41.0,"MO":41.0,"MT":39.0,"NE":39.5,"NV":48.4,"NH":51.5,"NJ":52.0,"NM":53.0,
 "NY":56.0,"NC":48.3,"ND":31.5,"OH":44.5,"OK":32.5,"OR":56.0,"PA":49.0,"RI":56.5,
 "SC":41.0,"SD":35.5,"TN":35.0,"TX":43.0,"UT":38.0,"VT":65.0,"VA":52.8,"WA":58.5,
 "WV":28.5,"WI":49.4,"WY":27.0,
}

# ---------------------------------------------------------------------------
# REAL: National demographic generic-ballot table (the racial-group model).
# - cvap_share: group share of citizen voting-age population. Source: ACS / Pew, ~2024.
# - turnout:    share of eligible who voted, 2024. Source: Census CPS Voting Supplement (approx).
# - dem2p:      two-party Democratic support among the group's voters, 2024.
#               Source: Catalist / AP VoteCast / Pew validated voters (estimates).
# Calibrated so the national two-party Dem share lands ~48.2% (≈ 2024 House popular vote).
# As of: 2024 general. All three columns are user-adjustable in-app (sliders).
# ---------------------------------------------------------------------------
GROUPS = [
 # key,        label,                  cvap_share, turnout, dem2p
 ("white",    "White (non-Hispanic)", 0.665,      0.67,    0.41),
 ("black",    "Black",                0.123,      0.58,    0.86),
 ("hispanic", "Hispanic / Latino",    0.140,      0.50,    0.52),
 ("asian",    "Asian / Pacific Is.",  0.047,      0.52,    0.56),
 ("native",   "Native American",      0.007,      0.48,    0.55),
 ("other",    "Multiracial / Other",  0.018,      0.52,    0.52),
]

# Seats–votes translation for the House (uniform-swing curve).
# demSeatShare = 0.5 + swing_ratio*(dem2p - 0.5) - seat_bias
# Calibrated to 2024 (D 215 / R 220) at a national two-party Dem share of ~0.482.
SEATS_VOTES = {"swing_ratio": 2.0, "seat_bias": -0.030, "house_size": 435}

# Senate class election years (Class I:2024/2030/2036, II:2026/2032, III:2028/2034).
SENATE_CLASS_YEARS = {"1":[2030,2036],"2":[2026,2032],"3":[2028,2034]}

PARTY = {"Democrat":"D","Republican":"R","Independent":"I"}
# Both current independents (Sanders-VT, King-ME) caucus with Democrats.
CAUCUS = {"D":"D","R":"R","I":"D"}

def load_cd_dem2p():
    """Per-state list of each congressional district's 2024 two-party Dem share (%), by district #."""
    path = DATA / "pres_by_cd_2024.csv"
    if not path.exists():
        path = ROOT / "Resources" / "pres_by_cd_2024.csv"
    if not path.exists():
        return {}
    # Backfill for districts left blank in the source (two-party Dem %, 2024, approx).
    CD_FALLBACK = {"NY-21": 39.8}   # Stefanik's upstate seat — Trump ~R+20 in 2024
    import csv as _csv
    acc = {}
    with open(path, newline="", encoding="utf-8-sig") as f:
        for row in _csv.DictReader(f):
            cd = (row.get("CD") or "").strip()
            if "-" not in cd:
                continue
            st, dist = cd.split("-", 1)
            num = 1 if dist.upper() in ("AL", "00", "ATL") else int(dist)
            try:
                h = float((row["Harris"] or "0").replace(",", "").strip() or 0)
                t = float((row["Trump"] or "0").replace(",", "").strip() or 0)
            except ValueError:
                h = t = 0
            if h + t > 0:
                acc.setdefault(st, []).append((num, h / (h + t) * 100))
            elif cd in CD_FALLBACK:
                acc.setdefault(st, []).append((num, CD_FALLBACK[cd]))
    return {st: [round(x[1], 2) for x in sorted(lst)] for st, lst in acc.items()}


def main():
    census = json.load(open(DATA/"census_seed.json"))["states"]
    senate = json.load(open(DATA/"senate_seed.json"))
    cd_dem2p = load_cd_dem2p()
    (ROOT/"Resources").mkdir(exist_ok=True)
    src = DATA/"pres_by_cd_2024.csv"
    if src.exists():
        (ROOT/"Resources"/"pres_by_cd_2024.csv").write_text(src.read_text(encoding="utf-8-sig"), encoding="utf-8")

    states = []
    for name, code in POSTAL.items():
        if name == "District of Columbia":
            continue
        c = census[name]
        states.append({
            "code": code, "name": name,
            "pop2020": c["pop2020"], "seats2020": c["seats2020"],
            "pop2024": c.get("pop2024"), "base2020": c.get("base2020"),
            "ev2020": c["seats2020"] + 2,            # House seats + 2 senators
            "pres2024Dem2p": PRES2024_DEM2P[code],
            "cdDem2p": cd_dem2p.get(code, []),       # per-district 2024 two-party Dem % (for EV splits)
            "tile": list(TILE[code]),
        })
    # DC: 3 electoral votes, no House apportionment / no Senate.
    dc = {"code":"DC","name":"District of Columbia","pop2020":689545,"seats2020":0,
          "pop2024":678972,"base2020":689546,"ev2020":3,
          "pres2024Dem2p":PRES2024_DEM2P["DC"],"cdDem2p":[],"tile":list(TILE["DC"]),"nonState":True}

    senate_seats = []
    for s in senate:
        p = PARTY.get(s["party"], "I")
        senate_seats.append({
            "state": s["state"], "class": s["class"], "party": p,
            "caucus": CAUCUS[p], "holder": s["name"],
        })
    senate_seats.sort(key=lambda x:(x["state"], x["class"]))

    groups = [{"key":k,"label":l,"cvapShare":cv,"turnout":t,"dem2p":d}
              for (k,l,cv,t,d) in GROUPS]

    dataset = {
        "meta": {
            "generated_by": "tools/gen_data.py",
            "sources": {
                "apportionment": "U.S. Census Bureau, 2020 Census Apportionment Table 1 (apportionment population as of April 1, 2020).",
                "estimates":     "U.S. Census Bureau, Population Estimates Program, Vintage 2024 (POPESTIMATE2024, as of July 1, 2024).",
                "senate":        "unitedstates/congress-legislators (current senators: state, class, party).",
                "presidential":  "2024 certified presidential results, two-party D share (AP / Cook Political Report), approximate.",
                "demographics":  "ACS / Pew (CVAP shares), Census CPS (turnout), Catalist / AP VoteCast / Pew validated voters (group support), ~2024.",
            },
            "as_of": "Assembled 2026-06-24. House apportionment fixed until the 2030 Census.",
        },
        "states": states + [dc],
        "senateSeats": senate_seats,
        "groups": groups,
        "seatsVotes": SEATS_VOTES,
        "senateClassYears": SENATE_CLASS_YEARS,
    }

    # sanity checks
    assert sum(s["seats2020"] for s in states) == 435, "apportioned seats != 435"
    assert sum(s["ev2020"] for s in dataset["states"]) == 538, "electoral votes != 538"
    assert len(senate_seats) == 100, "senate seats != 100"
    from collections import Counter
    cc = Counter(s["class"] for s in senate_seats)
    assert cc == {1:33,2:33,3:34}, f"senate class counts off: {cc}"
    # per-CD coverage: each state's CD count should match its apportioned seats (warn if not)
    mismatch = [(s["code"], len(s["cdDem2p"]), s["seats2020"]) for s in states
                if s["cdDem2p"] and len(s["cdDem2p"]) != s["seats2020"]]
    if mismatch:
        print("  ! CD-count mismatches (state, cds, seats):", mismatch)
    n_cd = sum(1 for s in states if s["cdDem2p"])
    print(f"  per-CD presidential data: {n_cd}/50 states")

    (ROOT/"Resources").mkdir(exist_ok=True)
    pretty = json.dumps(dataset, indent=1, ensure_ascii=False)
    (ROOT/"Resources"/"dataset.json").write_text(pretty, encoding="utf-8")

    # Phase 2 redistricting pilots (all feasible states). Prefer the freshly built data/ copy; fall
    # back to the committed Resources/ copy so a plain ./build.sh works on a clean checkout.
    pilots_path = DATA / "pilots.json"
    if not pilots_path.exists():
        pilots_path = ROOT / "Resources" / "pilots.json"
    pilots_compact = ""
    n_pilots = 0
    if pilots_path.exists():
        pf = json.load(open(pilots_path))
        n_pilots = len(pf.get("pilots", []))
        pilots_compact = json.dumps(pf, ensure_ascii=False, separators=(",", ":"))
        (ROOT/"Resources"/"pilots.json").write_text(
            json.dumps(pf, ensure_ascii=False), encoding="utf-8")

    # Embed into Swift as raw string literals (no runtime file dependency).
    assert '"###' not in pretty and '"###' not in pilots_compact
    swift = ("// AUTO-GENERATED by tools/gen_data.py — do not edit by hand.\n"
             "import Foundation\n\nenum GeneratedData {\n"
             "    static let datasetJSON = ###\"\"\"\n" + pretty + "\n\"\"\"###\n")
    if pilots_compact:
        swift += "    static let pilotsJSON: String? = ###\"\"\"\n" + pilots_compact + "\n\"\"\"###\n"
    else:
        swift += "    static let pilotsJSON: String? = nil\n"
    swift += "}\n"
    (ROOT/"Sources").mkdir(exist_ok=True)
    (ROOT/"Sources"/"GeneratedData.swift").write_text(swift, encoding="utf-8")
    print(f"✓ wrote Resources/dataset.json and Sources/GeneratedData.swift "
          f"({len(states)} states, {len(senate_seats)} senate seats, {n_pilots} redistricting pilots)")

if __name__ == "__main__":
    main()
