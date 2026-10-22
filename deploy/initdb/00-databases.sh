#!/bin/sh
# initdb/00-databases.sh — per-service databases for the adopted stack.
# Runs once on first postgres start (docker-entrypoint-initdb.d).
set -e
for db in odoo decidim; do
  psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -tc \
    "SELECT 1 FROM pg_database WHERE datname = '$db'" | grep -q 1 \
    || psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -c "CREATE DATABASE $db"
done
