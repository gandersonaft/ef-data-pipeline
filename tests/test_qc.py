from app.qc import check_condition_factor, check_pass_progression, summarize


def test_check_pass_progression_flags_increase():
    fish_rows = [
        {"run_id": 1, "species": "sal", "lifestage": "fry", "fish_multiplier": 1},
        {"run_id": 1, "species": "sal", "lifestage": "fry", "fish_multiplier": 1},
        {"run_id": 2, "species": "sal", "lifestage": "fry", "fish_multiplier": 1},
        {"run_id": 2, "species": "sal", "lifestage": "fry", "fish_multiplier": 1},
        {"run_id": 2, "species": "sal", "lifestage": "fry", "fish_multiplier": 1},
    ]
    run_pass_no = {1: 1, 2: 2}

    flags = check_pass_progression(fish_rows, run_pass_no)

    assert len(flags) == 1
    assert flags[0]["type"] == "pass_progression"
    assert flags[0]["species"] == "sal"
    assert flags[0]["lifestage"] == "fry"


def test_check_pass_progression_no_flag_when_declining_or_equal():
    fish_rows = [
        {"run_id": 1, "species": "trt", "lifestage": "parr", "fish_multiplier": 1},
        {"run_id": 1, "species": "trt", "lifestage": "parr", "fish_multiplier": 1},
        {"run_id": 2, "species": "trt", "lifestage": "parr", "fish_multiplier": 1},
    ]
    run_pass_no = {1: 1, 2: 2}

    assert check_pass_progression(fish_rows, run_pass_no) == []


def test_check_pass_progression_respects_bulk_multiplier():
    fish_rows = [
        {"run_id": 1, "species": "eel", "lifestage": None, "fish_multiplier": 3},  # bulk count of 3
        {"run_id": 2, "species": "eel", "lifestage": None, "fish_multiplier": 5},  # bulk count of 5 > 3
    ]
    run_pass_no = {1: 1, 2: 2}

    flags = check_pass_progression(fish_rows, run_pass_no)

    assert len(flags) == 1
    assert flags[0]["species"] == "eel"


def test_check_condition_factor_flags_out_of_range():
    fish_rows = [
        {"global_id": "a", "condition_factor": 0.4},   # too low
        {"global_id": "b", "condition_factor": 1.0},   # fine
        {"global_id": "c", "condition_factor": 2.0},   # too high
        {"global_id": "d", "condition_factor": None},  # no weight recorded — not a flag
    ]

    flags = check_condition_factor(fish_rows)

    assert {f["fish_global_id"] for f in flags} == {"a", "c"}


def test_summarize_ok_when_no_flags():
    status, flags = summarize([], [])
    assert status == "ok"
    assert flags == []


def test_summarize_flagged_when_any_flags_present():
    status, flags = summarize([{"type": "pass_progression"}], [{"type": "condition_factor_out_of_range"}])
    assert status == "flagged"
    assert len(flags) == 2
