\set ON_ERROR_STOP on

BEGIN;
REVOKE pg_read_all_data, pg_write_all_data FROM aviation_serve, aviation_ingest;
REVOKE ALL ON DATABASE aviation FROM PUBLIC;
GRANT CONNECT ON DATABASE aviation TO aviation_serve, aviation_ingest;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO aviation_serve;
GRANT USAGE, CREATE ON SCHEMA public TO aviation_ingest;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM aviation_serve;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM aviation_serve;
GRANT SELECT ON source_versions, aviation_records, manifests, manifest_versions,
  active_manifest, ingestion_runs TO aviation_serve;
GRANT SELECT, INSERT, UPDATE, DELETE ON weather_cache, provider_budgets,
  provider_cooldowns, admission_buckets TO aviation_serve;
ALTER ROLE aviation_serve NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
ALTER ROLE aviation_ingest NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
COMMIT;
