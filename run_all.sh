#!/usr/bin/env bash
# Builds the whole database from scratch, then runs every analysis.
# Usage: ./run_all.sh [mysql_user]    (you will be prompted for the password)
set -e
USER_NAME="${1:-root}"
run() { echo "-> $1"; mysql -u "$USER_NAME" -p < "sql/$1"; }

echo "== Build database =="
for f in 01_schema.sql 02_seed_data.sql 03_views.sql 06_funnel_seed.sql 08_marketing_seed.sql; do run "$f"; done

echo "== Analyses (results print to the terminal) =="
for f in 04_analysis_queries.sql 05_purchase_gap_churn.sql 07_funnel_ab_analysis.sql 09_clv_cac_analysis.sql; do run "$f"; done
