# EF Data Pipeline & DB

End-to-end data pipeline for NEPS electrofishing surveys:

```
Survey123 (efish_neps_v8)
    │  ArcGIS Online webhook (POST)
    ▼
FastAPI webhook receiver (app/)
    │  asyncpg transaction + Supabase Storage upload
    ▼
Supabase Postgres + PostGIS + Storage (supabase/)
    │  read-only pooled connection
    ▼
R Shiny reporting portal (shiny_app/)  →  Posit Connect / shinyapps.io
```

The Survey123 form this pipeline ingests lives at
`C:\Users\graem\ArcGIS\My Survey Designs\8533e51b881b43b4b7281ff5753d42e2\` (`form_id=efish_neps_v8`,
"NEPS Electrofishing Survey"). This project does not modify that form — it only consumes its submissions.

## Layout

- `supabase/` — `schema.sql` (DDL), `roles.sql` (least-privilege DB roles), `seed_sites.py` (loads
  `data/site_data.csv` into the `sites` table).
- `data/site_data.csv` — copy of the form's site lookup CSV (source: the XLSForm project's
  `media/site_data.csv`). Re-copy from there whenever the master site list changes, then re-run
  `seed_sites.py`.
- `app/` — FastAPI webhook receiver (`/webhook/survey123`).
- `tests/` — pytest suite + fixtures + manual e2e testing notes (`tests/README_e2e.md`).
- `shiny_app/` — R Shiny reporting portal (3 tabs: Depletion & Density, Length-Frequency & Condition,
  QC & Photo Review).
- `scripts/reprocess_webhook_log.py` — replay failed webhook deliveries from the `webhook_log` table.

## Quick start (local dev)

1. Copy `.env.example` → `.env` and fill in real values (Supabase connection string, ArcGIS OAuth
   client credentials, storage bucket name, webhook shared secret).
2. Apply the schema to your Supabase project (SQL editor, or `psql "$DATABASE_URL" -f supabase/schema.sql`
   then `-f supabase/roles.sql`).
3. Seed sites: `python supabase/seed_sites.py`
4. Install and run the API: `pip install -r app/requirements.txt && uvicorn app.main:app --reload`
5. Run tests: `pytest tests/`
6. For a real Survey123 round-trip test, see `tests/README_e2e.md`.
7. Run the Shiny app: copy `shiny_app/.Renviron.example` → `shiny_app/.Renviron`, fill in the
   `shiny_reader` credentials, then `R -e "shiny::runApp('shiny_app')"`.

## Deployment (Render)

The webhook receiver is deployed at `https://ef-data-pipeline-webhook.onrender.com` (Render web
service `ef-data-pipeline-webhook`, Python runtime, auto-deploys from `main`).

**Database connection gotcha that cost us a failed deploy, so it's written down here**: Supabase's
"direct" connection host (`db.<project-ref>.supabase.co:5432`) is IPv6-only unless you've paid for
Supabase's IPv4 add-on. Render — like Vercel, GitHub Actions, and Retool — has no IPv6 egress, so a
direct-host `DATABASE_URL` builds fine and then crashes on startup with `OSError: [Errno 101] Network
is unreachable` the instant asyncpg tries to connect. Use Supabase's **Supavisor pooler** instead
(session mode, port 5432): get the exact hostname from Supabase Dashboard → your project → **Connect**
→ Session pooler. Don't guess the hostname — it's `aws-<N>-<region>.pooler.supabase.com` where `<N>`
varies per project (we hit `aws-0-` for one eu-west-2 project when the correct value was `aws-1-`), and
a wrong guess fails with a *different*, confusing error (`tenant/user not found`) rather than a
DNS/network failure. The pooler username is always `<role>.<project-ref>`, not just `<role>`.

## Known open items

See the bottom of the implementation plan for the full list; the important ones:

- Whether ArcGIS Online delivers the full nested submission (event + passes + fish + photos + widths)
  in a single webhook POST, or fires separately per edited sub-layer, is **unverified** until a real
  test submission is made against a live webhook (`tests/README_e2e.md` walks through this). The
  receiver is written to handle either case.
- No `weight` field exists in the current form — `wet_weight_g`/`condition_factor` will be `NULL` for
  all real submissions today. The schema and Shiny app support it for when/if it's added to the form.
- Photos are site-level only (`rep_photos`), never per-fish.
