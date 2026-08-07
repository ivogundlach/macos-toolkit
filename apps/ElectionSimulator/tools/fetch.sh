#!/bin/bash
# fetch.sh — download the REAL source data that seeds the simulator (raw bytes only).
# Re-run to refresh. Outputs into data/. gen_data.py consumes census_seed.json + senate_seed.json.
set -euo pipefail
cd "$(dirname "$0")/../data"

echo "▸ 2020 apportionment population + seats (Census Table 1)…"
curl -sSL -o apportionment-2020.xlsx \
  "https://www2.census.gov/programs-surveys/decennial/2020/data/apportionment/apportionment-2020-table01.xlsx"

echo "▸ state population estimates, Vintage 2024 (Census PEP)…"
curl -sSL -o NST-EST2024.csv \
  "https://www2.census.gov/programs-surveys/popest/datasets/2020-2024/state/totals/NST-EST2024-ALLDATA.csv"

echo "▸ current senators with class + party (unitedstates/congress-legislators)…"
curl -sSL -o legislators-current.json \
  "https://unitedstates.github.io/congress-legislators/legislators-current.json"

echo "▸ 2024 presidential results by congressional district (jaytimm)…"
curl -sSL -o pres_by_cd_2024.csv \
  "https://raw.githubusercontent.com/jaytimm/PresElectionResults/master/data-raw/2024%20Pres%20by%20CD%20-%20Main.csv"

echo "▸ pilot-state (Iowa) redistricting layer…"
curl -sSL -o counties-geojson.json "https://raw.githubusercontent.com/plotly/datasets/master/geojson-counties-fips.json"
curl -sSL -o county_adjacency.txt  "https://www2.census.gov/geo/docs/reference/county_adjacency.txt"
curl -sSL -o county_pres_2020.csv  "https://raw.githubusercontent.com/tonmcg/US_County_Level_Election_Results_08-24/master/2020_US_County_Level_Presidential_Results.csv"
curl -sSL -o co-est2024.csv        "https://www2.census.gov/programs-surveys/popest/datasets/2020-2024/counties/totals/co-est2024-alldata.csv"

echo "▸ normalizing into seed JSON…"
python3 parse_seeds.py
echo "▸ building redistricting pilots + neutral ensembles for all feasible states…"
python3 build_pilots.py

echo "▸ Georgia precinct-level pilot (MGGG precinct shapefile)…"
curl -sSL -o GA_precincts.zip \
  "https://raw.githubusercontent.com/mggg-states/GA-shapefiles/master/GA_precincts.zip"
rm -rf ga_precincts && mkdir -p ga_precincts && (cd ga_precincts && unzip -o -q ../GA_precincts.zip)
python3 build_ga_precincts.py
echo "✓ data refreshed"
