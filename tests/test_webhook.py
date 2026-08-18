import json

from httpx import ASGITransport, AsyncClient

from app import esri
from app.db import get_pool
from app.main import app, get_esri, get_storage
from tests.conftest import FakeConnection, FakePool


async def test_crc_challenge_returns_expected_response_token(client):
    """Esri's webhook validation handshake -- get this wrong and AGOL stops
    delivering events entirely, so it's worth pinning down exactly."""
    resp = await client.get("/webhook/survey123", params={"crc_token": "abc123"})

    assert resp.status_code == 200
    body = resp.json()
    assert body["response_token"] == esri.compute_crc_response_token("abc123")
    assert body["response_token"].startswith("sha256=")


async def test_happy_path_insert(client, sample_payload):
    resp = await client.post("/webhook/survey123", content=json.dumps(sample_payload))

    assert resp.status_code == 200
    body = resp.json()
    assert body["event_id"] == 1
    assert body["runs"] == 2
    assert body["fish"] == 10
    assert body["photos"] == 2
    assert body["qc_status"] == "ok"
    assert body["qc_flags"] == []


async def test_qc_flag_pass_progression(client, qc_flagged_payload):
    resp = await client.post("/webhook/survey123", content=json.dumps(qc_flagged_payload))

    assert resp.status_code == 200
    body = resp.json()
    assert body["qc_status"] == "flagged"
    assert any(
        f["type"] == "pass_progression" and f["species"] == "sal" and f["lifestage"] == "fry"
        for f in body["qc_flags"]
    )


async def test_condition_factor_never_set_directly_by_api(client, fake_conn, sample_payload):
    """wet_weight_g/condition_factor are never part of the fish_records INSERT the API
    issues — condition_factor is exclusively DB-trigger-computed (schema.sql), and no
    weight field exists on the form today, so the API must never fabricate a value."""
    resp = await client.post("/webhook/survey123", content=json.dumps(sample_payload))
    assert resp.status_code == 200

    fish_inserts = [(q, a) for q, a in fake_conn.fetch_calls if "insert into fish_records" in q.lower()]
    assert len(fish_inserts) == 10
    for q, args in fish_inserts:
        # only the RETURNING clause may mention wet_weight_g/condition_factor (so the DB's
        # trigger-computed value can be read back) — the column list being inserted must not.
        column_list = q.lower().split("values", 1)[0]
        assert "wet_weight_g" not in column_list
        assert "condition_factor" not in column_list
        assert len(args) == 11  # matches the 11-column insert list, no weight among them


async def test_transaction_rollback_on_db_error(mock_esri, mock_storage, sample_payload):
    failing_conn = FakeConnection(fail_on_fish=True)
    failing_pool = FakePool(failing_conn)

    app.dependency_overrides[get_pool] = lambda: failing_pool
    app.dependency_overrides[get_esri] = lambda: mock_esri
    app.dependency_overrides[get_storage] = lambda: mock_storage
    try:
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as ac:
            resp = await ac.post("/webhook/survey123", content=json.dumps(sample_payload))
    finally:
        app.dependency_overrides.clear()

    assert resp.status_code == 500

    error_updates = [
        q for q, _ in failing_conn.executed
        if "update webhook_log" in q.lower() and "'error'" in q.lower()
    ]
    assert error_updates, "expected webhook_log to be marked as an error row, not processed"

    processed_updates = [
        q for q, _ in failing_conn.executed
        if "update webhook_log" in q.lower() and "'processed'" in q.lower()
    ]
    assert not processed_updates


async def test_attachment_download_and_upload(client, mock_esri, mock_storage, sample_payload):
    resp = await client.post("/webhook/survey123", content=json.dumps(sample_payload))
    assert resp.status_code == 200

    # sample_survey123_payload.json has 2 rep_photos entries, each with 1 mocked attachment
    assert mock_esri.list_attachments.call_count == 2
    assert mock_esri.download_attachment.call_count == 2
    assert mock_storage.upload_photo.call_count == 2

    for call in mock_storage.upload_photo.call_args_list:
        args, _ = call
        path = args[2]
        assert path.startswith("electrofishing/2026/Creran2/")
        assert path.endswith(".jpg")


async def test_unrecognized_payload_shape_rejected(client, fake_conn):
    """Neither our own test-envelope shape nor a real AGOL layerId/changesUrl
    notification -- should be rejected, not raise an unhandled 500."""
    resp = await client.post("/webhook/survey123", content=json.dumps({"something": "else"}))

    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "rejected"


async def test_malformed_payload_rejected(client, fake_conn):
    bad_payload = {
        "event": {"attributes": {"globalid": "{bad-event}", "site_type": "existing"}},  # missing site_code, survey_date
        "rep_pass": [],
        "rep_fish": [],
        "rep_photos": [],
        "rep_widths": [],
    }

    resp = await client.post("/webhook/survey123", content=json.dumps(bad_payload))

    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "rejected"

    error_updates = [
        q for q, _ in fake_conn.executed
        if "update webhook_log" in q.lower() and "'error'" in q.lower()
    ]
    assert error_updates
