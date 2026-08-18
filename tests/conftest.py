import json
import os
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock

# Required Settings fields must exist before app.config.get_settings() is ever called
# (it's lru_cached, so this must happen at import time, before any test runs).
os.environ.setdefault("DATABASE_URL", "postgresql://test:test@localhost/test")
os.environ.setdefault("SUPABASE_URL", "https://example.supabase.co")
os.environ.setdefault("SUPABASE_SERVICE_KEY", "test-service-key")
os.environ.setdefault("ARCGIS_CLIENT_ID", "test-client-id")
os.environ.setdefault("ARCGIS_CLIENT_SECRET", "test-client-secret")
os.environ.setdefault(
    "AGOL_FEATURE_SERVICE_URL",
    "https://services.arcgis.com/test/arcgis/rest/services/efish_neps_v8/FeatureServer",
)
os.environ.setdefault("WEBHOOK_SHARED_SECRET", "test-webhook-secret")
os.environ.setdefault("ENVIRONMENT", "development")

import asyncpg
import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient

from app import esri
from app.db import get_pool
from app.main import app, get_esri, get_storage

FIXTURES_DIR = Path(__file__).parent / "fixtures"


@pytest.fixture
def sample_payload() -> dict:
    return json.loads((FIXTURES_DIR / "sample_survey123_payload.json").read_text())


@pytest.fixture
def qc_flagged_payload() -> dict:
    return json.loads((FIXTURES_DIR / "sample_payload_qc_flagged.json").read_text())


class _NullAsyncCM:
    async def __aenter__(self):
        return None

    async def __aexit__(self, *exc):
        return False


class _AcquireCM:
    def __init__(self, conn):
        self._conn = conn

    async def __aenter__(self):
        return self._conn

    async def __aexit__(self, *exc):
        return False


class FakeConnection:
    """Minimal asyncpg.Connection stand-in covering exactly the queries crud.py
    and webhook_log.py issue, so the endpoint can be exercised without a real
    Postgres instance."""

    def __init__(self, fail_on_fish: bool = False):
        self.fail_on_fish = fail_on_fish
        self._site_id = 1
        self._event_id = 1
        self._run_id = 0
        self._fish_id = 0
        self._webhook_log_id = 0
        self.executed: list[tuple] = []
        self.fetch_calls: list[tuple] = []

    def transaction(self):
        return _NullAsyncCM()

    async def fetchrow(self, query: str, *args):
        self.fetch_calls.append((query, args))
        q = query.lower()

        if "insert into webhook_log" in q:
            self._webhook_log_id += 1
            return {"id": self._webhook_log_id}

        if "select site_id from sites" in q:
            return {"site_id": self._site_id}

        if "insert into sites" in q:
            return {"site_id": self._site_id}

        if "insert into electrofishing_events" in q:
            return {"event_id": self._event_id}

        if "insert into electrofishing_runs" in q:
            self._run_id += 1
            return {"run_id": self._run_id}

        if "insert into fish_records" in q:
            if self.fail_on_fish:
                raise asyncpg.PostgresError("simulated DB failure inserting fish_records")
            self._fish_id += 1
            (
                global_id, parent_global_id, run_id, entry_mode, species, length_mm,
                lifestage, scaled, tissue_tube, count_bulk, fish_multiplier,
            ) = args
            return {
                "fish_id": self._fish_id,
                "run_id": run_id,
                "species": species,
                "lifestage": lifestage,
                "length_mm": length_mm,
                "wet_weight_g": None,
                "condition_factor": None,
                "fish_multiplier": fish_multiplier,
            }

        raise AssertionError(f"FakeConnection.fetchrow: unexpected query: {query[:80]!r}")

    async def execute(self, query: str, *args):
        self.executed.append((query, args))
        return "OK"


class FakePool:
    def __init__(self, conn: FakeConnection):
        self.conn = conn

    def acquire(self):
        return _AcquireCM(self.conn)


@pytest.fixture
def fake_conn() -> FakeConnection:
    return FakeConnection()


@pytest.fixture
def fake_pool(fake_conn) -> FakePool:
    return FakePool(fake_conn)


@pytest.fixture
def mock_esri():
    m = MagicMock()
    m.get_token = AsyncMock(return_value="fake-token")
    m.verify_webhook_signature = MagicMock(return_value=True)
    m.normalize_guid = esri.normalize_guid
    m.list_attachments = AsyncMock(
        return_value=[esri.AttachmentMeta(attachment_id="1", name="photo.jpg", content_type="image/jpeg")]
    )
    m.download_attachment = AsyncMock(return_value=(b"fake-image-bytes", "image/jpeg"))
    m.fetch_full_submission = AsyncMock()
    return m


@pytest.fixture
def mock_storage():
    m = MagicMock()
    m.ext_from_content_type = MagicMock(return_value="jpg")
    m.build_storage_path = MagicMock(
        side_effect=lambda survey_date, site_code, global_id, ext: (
            f"electrofishing/{survey_date.year}/{site_code}/{global_id}.{ext}"
        )
    )
    m.upload_photo = AsyncMock(return_value=None)
    m.sign_url = MagicMock(return_value="https://example.supabase.co/storage/v1/object/sign/fake")
    return m


@pytest_asyncio.fixture
async def client(fake_pool, mock_esri, mock_storage):
    app.dependency_overrides[get_pool] = lambda: fake_pool
    app.dependency_overrides[get_esri] = lambda: mock_esri
    app.dependency_overrides[get_storage] = lambda: mock_storage
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac
    app.dependency_overrides.clear()
