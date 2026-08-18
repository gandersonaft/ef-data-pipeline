"""
Pydantic models for the real efish_neps_v8 payload shape.

Every *Attributes model uses extra="ignore" because the live feature service
carries dozens of presentation-only `calculate` fields (fish_row, fish_len_tag,
pass_summary, pass_summary_text, catch_summary, catch_summary_1/2/3,
freq_sal_html, freq_trt_html, all_fish_table, fish_table_pass, cutoff_suggested,
dep_*_json, den_*, site_*, etc.) that must be silently dropped rather than
cause validation failures — only the fields we actually persist are declared.

`species_quick`, `species_other_sel`, and `calc_stage` are deliberately never
declared here: `species` and `lifestage` are the only fields that should ever
be read for those concepts (see schema.sql comments / project memory
calc_stage_unused.md).

GUID field casing (`globalid` vs `GlobalID`) is assumed lowercase, matching
this form's published service definition, but has not been confirmed against
a captured real webhook payload — verify against tests/README_e2e.md's e2e
walkthrough and adjust the aliases below if AGOL sends different casing.
"""

from __future__ import annotations

from datetime import date, datetime, time, timezone
from typing import Any

from pydantic import BaseModel, ConfigDict, field_validator


def _epoch_ms_to_date(value: Any) -> date | None:
    if value is None or value == "":
        return None
    if isinstance(value, (int, float)):
        return datetime.fromtimestamp(value / 1000, tz=timezone.utc).date()
    if isinstance(value, str):
        return date.fromisoformat(value[:10])
    return value


def _parse_time(value: Any) -> time | None:
    if value is None or value == "":
        return None
    if isinstance(value, str):
        return time.fromisoformat(value[:8])
    return value


class Geometry(BaseModel):
    model_config = ConfigDict(extra="ignore")
    x: float | None = None
    y: float | None = None


class EventAttributes(BaseModel):
    model_config = ConfigDict(extra="ignore")

    globalid: str
    objectid: int | None = None

    site_code: str
    site_type: str
    site_select: str | None = None
    new_site_name: str | None = None
    new_river_name: str | None = None

    catchment: str | None = None
    river_name: str | None = None

    survey_date: Any
    start_time: Any = None
    end_time: Any = None

    lon_wgs84: float | None = None
    lat_wgs84: float | None = None
    easting: int | None = None
    northing: int | None = None

    temp_water: float | None = None
    conductivity: int | None = None
    water_lvl: str | None = None
    water_clr: str | None = None
    water_sample: str | None = None

    anode_op: str | None = None
    bucket_op: str | None = None
    banner_net: str | None = None
    hand_net: str | None = None
    scribe: str | None = None
    processing: str | None = None
    other_staff: str | None = None
    eq_type: str | None = None
    eq_model: str | None = None
    volts: int | None = None
    stop_nets: str | None = None
    anaesthetic: str | None = None

    site_length_lb: float | None = None
    site_length_rb: float | None = None
    site_length: float | None = None
    final_avg_width: float | None = None
    final_site_area: float | None = None

    sub_be: int | None = None
    sub_bo: int | None = None
    sub_co: int | None = None
    sub_pe: int | None = None
    sub_gr: int | None = None
    sub_sa: int | None = None
    sub_si: int | None = None
    sub_ho: int | None = None
    sub_total: int | None = None
    flow_sm: int | None = None
    flow_dp: int | None = None
    flow_sp: int | None = None
    flow_dg: int | None = None
    flow_sg: int | None = None
    flow_ru: int | None = None
    flow_ri: int | None = None
    flow_to: int | None = None
    flow_total: int | None = None

    sal_fry_parr_cutoff: int | None = None
    trt_fry_parr_cutoff: int | None = None

    pollution: str | None = None
    pollution_notes: str | None = None
    stocking: str | None = None
    stocking_notes: str | None = None
    final_comments: str | None = None

    # form's own self-reported rollups — captured as-is into
    # electrofishing_events.form_reported_summary for QC cross-check display only
    catches_sal_fry: Any = None
    catches_sal_parr: Any = None
    catches_trt_fry: Any = None
    catches_trt_parr: Any = None
    catches_eel: Any = None
    site_sal_fry: Any = None
    site_sal_parr: Any = None
    site_trt_fry: Any = None
    site_trt_parr: Any = None
    site_eel: Any = None
    site_other: Any = None
    site_total: Any = None
    den_sal_fry: Any = None
    den_sal_parr: Any = None
    den_trt_fry: Any = None
    den_trt_parr: Any = None

    @field_validator("survey_date", mode="after")
    @classmethod
    def _coerce_survey_date(cls, v: Any) -> date:
        d = _epoch_ms_to_date(v)
        if d is None:
            raise ValueError("survey_date is required")
        return d

    @field_validator("start_time", "end_time", mode="after")
    @classmethod
    def _coerce_time(cls, v: Any) -> time | None:
        return _parse_time(v)

    def effective_site_code(self) -> str:
        return self.new_site_name if self.site_type == "new" else (self.site_select or self.site_code)

    def form_reported_summary(self) -> dict:
        return {
            k: getattr(self, k)
            for k in (
                "catches_sal_fry", "catches_sal_parr", "catches_trt_fry", "catches_trt_parr",
                "catches_eel", "site_sal_fry", "site_sal_parr", "site_trt_fry", "site_trt_parr",
                "site_eel", "site_other", "site_total",
                "den_sal_fry", "den_sal_parr", "den_trt_fry", "den_trt_parr",
            )
            if getattr(self, k) is not None
        }


class EventFeature(BaseModel):
    model_config = ConfigDict(extra="ignore")
    attributes: EventAttributes
    geometry: Geometry | None = None


class RunAttributes(BaseModel):
    model_config = ConfigDict(extra="ignore")

    globalid: str
    parentglobalid: str
    pass_no: int
    anode_time: int | None = None
    total_pass_time: int | None = None

    pass_sal_fry: int | None = None
    pass_trt_fry: int | None = None
    pass_sal_parr: int | None = None
    pass_trt_parr: int | None = None
    pass_eel: int | None = None
    pass_other: int | None = None
    pass_total: int | None = None


class RunFeature(BaseModel):
    model_config = ConfigDict(extra="ignore")
    attributes: RunAttributes


class FishAttributes(BaseModel):
    model_config = ConfigDict(extra="ignore")

    globalid: str
    parentglobalid: str
    entry_mode: str | None = None
    species: str
    length: int | None = None
    lifestage: str | None = None
    scaled: str | None = None
    tissue_tube: str | None = None
    count_bulk: int | None = None
    fish_multiplier: int | None = None


class FishFeature(BaseModel):
    model_config = ConfigDict(extra="ignore")
    attributes: FishAttributes


class PhotoAttributes(BaseModel):
    model_config = ConfigDict(extra="ignore")
    globalid: str
    parentglobalid: str
    objectid: int | None = None
    photo_caption: str | None = None


class PhotoFeature(BaseModel):
    model_config = ConfigDict(extra="ignore")
    attributes: PhotoAttributes


class WidthAttributes(BaseModel):
    model_config = ConfigDict(extra="ignore")
    globalid: str
    parentglobalid: str
    width_id: int | None = None
    wet_width: float | None = None
    bed_width: float | None = None
    bankfull_width: float | None = None


class WidthFeature(BaseModel):
    model_config = ConfigDict(extra="ignore")
    attributes: WidthAttributes


class RunWithFish(BaseModel):
    model_config = ConfigDict(extra="ignore")
    run: RunAttributes
    fish: list[FishAttributes]


class NormalizedSubmission(BaseModel):
    """The assembled tree consumed by crud.py/qc.py, regardless of whether the
    webhook delivered a full nested payload directly or it was reassembled via
    esri.fetch_full_submission()."""

    model_config = ConfigDict(extra="ignore")

    event: EventAttributes
    geometry: Geometry | None = None
    runs: list[RunWithFish]
    photos: list[PhotoAttributes]
    widths: list[WidthAttributes]
    raw_payload: dict
