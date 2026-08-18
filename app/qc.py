"""
Automated QC flagging. Computed here (not in DB triggers) because pass-
progression checking needs to compare sibling rows across passes within the
same submission, with full context already in memory right after insert —
easier to express and test in Python than in a row-level trigger. The DB
only stores the resulting flags (electrofishing_events.qc_status/qc_flags).

Condition-factor NULLs (no weight recorded — true for essentially all current
submissions, since the form has no weight field) are simply skipped, not
flagged.
"""

from __future__ import annotations

from collections import defaultdict

CONDITION_FACTOR_MIN = 0.6
CONDITION_FACTOR_MAX = 1.8


def check_pass_progression(fish_rows: list[dict], run_pass_no: dict[int, int]) -> list[dict]:
    """
    fish_rows: rows returned by crud.upsert_fish (each has run_id, species,
    lifestage, fish_multiplier).
    run_pass_no: run_id -> pass_no, from crud.upsert_runs' inserted rows.

    Flags any (species, lifestage) group where a later pass's catch count
    exceeds an earlier pass's — computed strictly from the fish rows just
    inserted, never from the form's self-reported pass_* totals.
    """
    counts: dict[tuple[str, str | None], dict[int, int]] = defaultdict(lambda: defaultdict(int))

    for fish in fish_rows:
        pass_no = run_pass_no.get(fish["run_id"])
        if pass_no is None:
            continue
        key = (fish["species"], fish["lifestage"])
        counts[key][pass_no] += fish.get("fish_multiplier") or 1

    flags: list[dict] = []
    for (species, lifestage), by_pass in counts.items():
        ordered_passes = sorted(by_pass)
        for earlier, later in zip(ordered_passes, ordered_passes[1:]):
            if by_pass[later] > by_pass[earlier]:
                flags.append({
                    "type": "pass_progression",
                    "species": species,
                    "lifestage": lifestage,
                    "detail": (
                        f"pass {later} (n={by_pass[later]}) > pass {earlier} (n={by_pass[earlier]})"
                    ),
                })
    return flags


def check_condition_factor(fish_rows: list[dict]) -> list[dict]:
    flags: list[dict] = []
    for fish in fish_rows:
        k = fish.get("condition_factor")
        if k is None:
            continue
        k = float(k)
        if not (CONDITION_FACTOR_MIN <= k <= CONDITION_FACTOR_MAX):
            flags.append({
                "type": "condition_factor_out_of_range",
                "fish_global_id": fish.get("global_id") or fish.get("fish_id"),
                "value": k,
            })
    return flags


def summarize(*flag_lists: list[dict]) -> tuple[str, list[dict]]:
    flags: list[dict] = [f for flist in flag_lists for f in flist]
    status = "flagged" if flags else "ok"
    return status, flags
