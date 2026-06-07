"""Smoke test: the package imports and reports the expected version."""

import alidade


def test_version_matches_lockstep() -> None:
    assert alidade.__version__ == "0.0.1"
