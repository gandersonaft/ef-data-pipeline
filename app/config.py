from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    # Postgres (asyncpg DSN, Supabase pooled/pgbouncer port)
    database_url: str

    # Supabase Storage (photo uploads)
    supabase_url: str
    supabase_service_key: str
    storage_bucket: str = "ef-photos"
    signed_url_ttl_seconds: int = 3600

    # ArcGIS Online
    arcgis_org_id: str = "E0EowMpDSIln8rmj"
    arcgis_client_id: str
    arcgis_client_secret: str
    agol_feature_service_url: str

    # Webhook security
    webhook_shared_secret: str

    environment: str = "development"


@lru_cache
def get_settings() -> Settings:
    return Settings()
