#!/usr/bin/env python3
"""Build a compact, searchable SQLite nutrient DB from USDA FoodData Central
SR Legacy + Foundation Foods CSV dumps.

Usage:
  build_usda_db.py <sr_dir> <foundation_dir> <out.sqlite>

Only whole/generic foods (data_type sr_legacy_food, foundation_food) and the
~22 nutrients the app tracks are retained, keeping the bundled DB small.
"""
import csv, sqlite3, sys, os

# nutrient_id -> (key, display_name, unit)  [amounts in food_nutrient are per 100 g]
NUTRIENTS = {
    1008: ("kcal",       "Energy",                 "kcal"),
    1003: ("protein",    "Protein",                "g"),
    1087: ("calcium",    "Calcium",                "mg"),
    1089: ("iron",       "Iron",                   "mg"),   # toxicity-watch
    1090: ("magnesium",  "Magnesium",              "mg"),
    1091: ("phosphorus", "Phosphorus",             "mg"),
    1092: ("potassium",  "Potassium",              "mg"),
    1093: ("sodium",     "Sodium",                 "mg"),
    1095: ("zinc",       "Zinc",                   "mg"),   # toxicity-watch
    1098: ("copper",     "Copper",                 "mg"),
    1101: ("manganese",  "Manganese",              "mg"),
    1103: ("selenium",   "Selenium",               "ug"),
    1106: ("vitA_rae",   "Vitamin A (RAE)",        "ug"),   # toxicity-watch
    1109: ("vitE",       "Vitamin E (a-toco.)",    "mg"),
    1114: ("vitD",       "Vitamin D (D2+D3)",      "ug"),
    1162: ("vitC",       "Vitamin C",              "mg"),
    1177: ("folate",     "Folate, total",          "ug"),
    1178: ("vitB12",     "Vitamin B12",            "ug"),
    1183: ("vitK_mk4",   "Vitamin K (MK-4)",       "ug"),
    1185: ("vitK_phyllo","Vitamin K (phylloq.)",   "ug"),
    1272: ("dha",        "DHA (22:6 n-3)",         "g"),
    1278: ("epa",        "EPA (20:5 n-3)",         "g"),
}
KEEP_TYPES = {"sr_legacy_food", "foundation_food"}


def load_foods(d):
    rows = {}
    with open(os.path.join(d, "food.csv"), newline="", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            if r["data_type"] in KEEP_TYPES:
                rows[r["fdc_id"]] = (r["description"].strip(), r["data_type"])
    return rows


def load_nutrients(d, keep_fdc):
    out = []
    with open(os.path.join(d, "food_nutrient.csv"), newline="", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            nid = int(r["nutrient_id"]) if r["nutrient_id"] else 0
            if nid in NUTRIENTS and r["fdc_id"] in keep_fdc and r["amount"]:
                try:
                    out.append((int(r["fdc_id"]), nid, float(r["amount"])))
                except ValueError:
                    pass
    return out


def main():
    sr_dir, fdn_dir, out = sys.argv[1], sys.argv[2], sys.argv[3]
    foods = {}
    foods.update(load_foods(sr_dir))
    foods.update(load_foods(fdn_dir))
    fdc_ids = set(foods.keys())
    fn = load_nutrients(sr_dir, fdc_ids) + load_nutrients(fdn_dir, fdc_ids)

    if os.path.exists(out):
        os.remove(out)
    db = sqlite3.connect(out)
    db.executescript(
        """
        PRAGMA journal_mode=DELETE;
        CREATE TABLE nutrients(id INTEGER PRIMARY KEY, key TEXT, name TEXT, unit TEXT);
        CREATE TABLE foods(fdc_id INTEGER PRIMARY KEY, description TEXT, data_type TEXT, search TEXT);
        CREATE TABLE food_nutrients(fdc_id INTEGER, nutrient_id INTEGER, amount REAL);
        CREATE INDEX idx_fn_fdc ON food_nutrients(fdc_id);
        CREATE INDEX idx_foods_search ON foods(search);
        """
    )
    db.executemany("INSERT INTO nutrients VALUES (?,?,?,?)",
                   [(nid, k, n, u) for nid, (k, n, u) in NUTRIENTS.items()])
    db.executemany("INSERT INTO foods VALUES (?,?,?,?)",
                   [(int(fid), desc, dt, desc.lower()) for fid, (desc, dt) in foods.items()])
    db.executemany("INSERT INTO food_nutrients VALUES (?,?,?)", fn)
    db.commit()
    nf = db.execute("SELECT COUNT(*) FROM foods").fetchone()[0]
    nn = db.execute("SELECT COUNT(*) FROM food_nutrients").fetchone()[0]
    db.execute("VACUUM")
    db.close()
    print(f"foods={nf} food_nutrients={nn} nutrients={len(NUTRIENTS)} -> {out} "
          f"({os.path.getsize(out)//1024} KB)")


if __name__ == "__main__":
    main()
