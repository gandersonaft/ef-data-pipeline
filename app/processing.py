"""
Core submission-processing pipeline, shared between the webhook receiver
(app/main.py) and the polling fallback (scripts/poll_submissions.py).

Both ultimately arrive at a fully resolved queryRelatedRecords "tree" (from
esri.fetch_full_submission) and need the same normalize -> upload photos ->
upsert -> QC pipeline; this module is that shared pipeline so the two entry
points can't drift out of sync with each other.
"""

from __future__ import annotations

from pydantic import ValidationError

from app import crud, qc
from app.db import transaction
from app.esri import normalize_guid
from app.models import (
    EventAttributes,
    FishAttributes,
    Geometry,
    NormalizedSubmission,
    PhotoAttributes,
    RunAttributes,
    RunWithFish,
    WidthAttributes,
)


def _attrs(feature) -> dict:
    """Accepts either a bare attributes dict (our own assembled envelope shape,
    matching test fixtures) or an Esri {"attributes": {...}} feature wrapper
    (returned by esri.fetch_full_submission's queryRelatedRecords fallback)."""
    return feature["attributes"] if isinstance(feature, dict) and "attributes" in feature else feature


def build_normalized_submission(tree: dict, raw_payload: dict) -> NormalizedSubmission:
    event_feature = tree["event"]
    event = EventAttributes.model_validate(_attrs(event_feature))
    geometry = None
    if isinstance(event_feature, dict) and event_feature.get("geometry"):
        geometry = Geometry.model_validate(event_feature["geometry"])

    pass_list = [RunAttributes.model_validate(_attrs(p)) for p in tree.get("rep_pass", [])]
    photo_list = [PhotoAttributes.model_validate(_attrs(p)) for p in tree.get("rep_photos", [])]
    width_list = [WidthAttributes.model_validate(_attrs(w)) for w in tree.get("rep_widths", [])]

    # Validate fish rows individually rather than in one list comprehension:
    # this form has had required-field validation stripped for testing, so
    # incomplete rows (e.g. missing species) are a confirmed, real occurrence.
    # One bad row must not cost the entire submission -- passes, other valid
    # fish, photos, widths, event details -- when it's the only thing wrong.
    fish_list: list[FishAttributes] = []
    skipped_fish: list[dict] = []
    for f in tree.get("rep_fish", []):
        raw_attrs = _attrs(f)
        try:
            fish_list.append(FishAttributes.model_validate(raw_attrs))
        except ValidationError as e:
            skipped_fish.append({"attributes": raw_attrs, "error": str(e)})

    runs = [
        RunWithFish(
            run=run,
            fish=[f for f in fish_list if normalize_guid(f.parentglobalid) == normalize_guid(run.globalid)],
        )
        for run in pass_list
    ]

    return NormalizedSubmission(
        event=event, geometry=geometry, runs=runs, photos=photo_list, widths=width_list,
        raw_payload=raw_payload, skipped_fish=skipped_fish,
    )


async def download_and_upload_photos(
    submission: NormalizedSubmission, esri_mod, storage_mod, agol_feature_service_url: str
) -> list[tuple]:
    """Network I/O for attachments, done BEFORE the DB transaction opens."""
    rep_photos_url = f"{agol_feature_service_url.rstrip('/')}/1"  # rep_photos = related table id 1

    uploads: list[tuple] = []
    for photo in submission.photos:
        if photo.objectid is None:
            continue
        token = await esri_mod.get_token()
        attachments = await esri_mod.list_attachments(rep_photos_url, photo.objectid, token)
        for att in attachments:
            content, content_type = await esri_mod.download_attachment(
                rep_photos_url, photo.objectid, att.attachment_id, token
            )
            ext = storage_mod.ext_from_content_type(content_type)
            path = storage_mod.build_storage_path(
                submission.event.survey_date, submission.event.effective_site_code(),
                normalize_guid(photo.globalid), ext,
            )
            await storage_mod.upload_photo(content, content_type, path)
            url = storage_mod.sign_url(path)
            uploads.append((photo, path, url, content_type))
    return uploads


async def process_submission(
    pool, esri_mod, storage_mod, submission: NormalizedSubmission, agol_feature_service_url: str
) -> dict:
    """Upserts a submission and computes QC flags. Idempotent (ON CONFLICT
    upserts throughout), so safe to call more than once for the same event —
    both the webhook (up to 5x per submission) and the poller (every run,
    until the high-water mark advances) rely on that."""
    photo_uploads = await download_and_upload_photos(submission, esri_mod, storage_mod, agol_feature_service_url)

    async with transaction(pool) as conn:
        site_id = await crud.upsert_site(conn, submission.event)
        event_id = await crud.upsert_event(conn, submission, site_id)
        run_id_map = await crud.upsert_runs(conn, event_id, submission.runs)
        fish_rows = await crud.upsert_fish(conn, run_id_map, submission.runs)
        await crud.upsert_widths(conn, event_id, submission.widths)
        await crud.upsert_photos(conn, event_id, photo_uploads)

        run_pass_no = {
            run_id_map[normalize_guid(rwf.run.globalid)]: rwf.run.pass_no for rwf in submission.runs
        }
        pass_flags = qc.check_pass_progression(fish_rows, run_pass_no)
        k_flags = qc.check_condition_factor(fish_rows)
        incomplete_flags = (
            [{"type": "incomplete_fish_record", "count": len(submission.skipped_fish)}]
            if submission.skipped_fish else []
        )
        status, flags = qc.summarize(pass_flags, k_flags, incomplete_flags)
        await crud.update_qc(conn, event_id, status, flags)

    return {
        "event_id": event_id,
        "runs": len(run_id_map),
        "fish": len(fish_rows),
        "fish_skipped": len(submission.skipped_fish),
        "photos": len(photo_uploads),
        "qc_status": status,
        "qc_flags": flags,
    }
