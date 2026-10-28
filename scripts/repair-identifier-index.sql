BEGIN;
SELECT pg_advisory_xact_lock(13799201);
DO $$
BEGIN
  IF EXISTS (
    SELECT FROM pg_index
    WHERE indexrelid = to_regclass('public.aviation_faa_lid') AND NOT indisvalid
  ) THEN
    DROP INDEX public.aviation_faa_lid;
  END IF;
END
$$;
CREATE INDEX IF NOT EXISTS aviation_faa_lid
ON public.aviation_records(kind, upper(data->>'faa_lid'), version_id);
COMMIT;
SELECT indisvalid, indisready
FROM pg_index WHERE indexrelid = 'public.aviation_faa_lid'::regclass;
