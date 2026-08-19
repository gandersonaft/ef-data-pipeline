-- ============================================================================
-- Migration 0003 -- river network overlay for Site Map, sourced from OS Open
-- Rivers (Ordnance Survey), Open Government Licence -- free to use and
-- redistribute with attribution ("Contains OS data (c) Crown copyright and
-- database right"). Clipped to the AFT_CEH network's extent (+5km buffer:
-- xmin 93842, ymin 605894.5, xmax 242629, ymax 763496.3, EPSG:27700) and
-- simplified (ST_SimplifyPreserveTopology, 30m tolerance) at load time by
-- scripts/load_river_network.R -- NOT the full national dataset (189,428
-- segments), and NOT the AFT_CEH network itself.
--
-- AFT also holds a second, separately licensed river network (AFT_CEH, from
-- the Centre for Ecology and Hydrology via SFCC) that carries AFT's own
-- catchment classification codes -- deliberately NOT loaded here or anywhere
-- else in this app. Its licence ("sfcc aft export/dig riv network/AFT_CEH/
-- CEH Rivers Copyright.doc") explicitly prohibits passing digital copies to
-- any other organisation, so it must never enter this (public) repo or any
-- exported file. See the plan addendum ("River Network Map Overlay") for the
-- full reasoning.
-- ============================================================================

create table river_network (
    segment_id    bigint generated always as identity primary key,
    os_identifier text unique,   -- OS Open Rivers' own GUID; natural key for idempotent reload
    name1         text,
    name2         text,
    form          text,          -- inlandRiver / lake / tidalRiver etc.
    flow          text,
    fictitious    boolean,
    length_m      numeric(10,1),
    geom_27700    geometry(LineString, 27700) not null,
    created_at    timestamptz not null default now()
);
create index idx_river_network_geom on river_network using gist (geom_27700);

-- Read access matches the live-data read-only convention. webhook_writer
-- gets full write access purely so scripts/load_river_network.R (a batch
-- loader, not part of the live submission pipeline) can delete-and-reload
-- the table idempotently, same as historical_fish's reload pattern.
grant select on river_network to shiny_reader;
grant select, insert, update, delete on river_network to webhook_writer;
