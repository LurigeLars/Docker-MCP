"""Fixed-purpose read-only AIRSEA pilot aggregate report for DockerLocal host runner.

No CLI parameters. Never reads or returns raw MMSI, vessel state, track,
coordinates, metadata, credentials or log content. No SQLite migrations.
"""
from __future__ import annotations

import json
import os
import sqlite3
import sys
from datetime import date, datetime, timezone
from pathlib import Path

MAX_DAYS = 14
AGGREGATE_COLUMNS = (
    "day",
    "ais_position_messages", "ais_static_messages",
    "ais_crossings_all", "ais_crossings_tanker",
    "ais_connected_seconds", "ais_disconnects",
    "adsb_ok", "adsb_errors", "opensky_ok", "opensky_errors",
    "ais_zone_w", "ais_zone_m", "ais_zone_e",
    "ais_vessels_w", "ais_vessels_m", "ais_vessels_e",
)
INTAKE_COLUMNS = (
    "frames_received", "accepted_positions", "accepted_static",
    "rejected_bad_json", "rejected_non_object", "rejected_unsupported",
    "rejected_structure", "rejected_identifier", "rejected_position",
    "rejected_outside_box", "rejected_duplicate_stale", "processing_errors",
)
REJECTION_COLUMNS = tuple(key for key in INTAKE_COLUMNS if key.startswith("rejected_"))


def _tracking_phase(day: str, since: str | None) -> str:
    if not since:
        return "UNKNOWN"
    try:
        since_day = datetime.fromisoformat(since.replace("Z", "+00:00")).date()
        day_date = date.fromisoformat(day)
    except (ValueError, TypeError):
        return "UNKNOWN"
    if day_date < since_day:
        return "PRE_INSTRUMENTATION_UNKNOWN"
    if day_date == since_day:
        return "PARTIAL_INSTALL_DAY"
    return "POST_INSTALLATION"


def _intake(conn: sqlite3.Connection, day: str) -> dict | None:
    row = conn.execute(
        "SELECT " + ",".join(INTAKE_COLUMNS) +
        " FROM ais_intake_day WHERE day=?", (day,),
    ).fetchone()
    if row is None:
        return None  # unknown, not inferred zero
    counts = dict(zip(INTAKE_COLUMNS, map(int, row)))
    accepted = counts["accepted_positions"] + counts["accepted_static"]
    rejected = sum(counts[k] for k in REJECTION_COLUMNS)
    errors = counts["processing_errors"]
    frame_count = counts["frames_received"]
    return {
        "frames": frame_count,
        "accepted": accepted,
        "accepted_positions": counts["accepted_positions"],
        "accepted_static": counts["accepted_static"],
        "rejected": rejected,
        "processing_errors": errors,
        "rejection_reasons": {
            k.removeprefix("rejected_"): counts[k]
            for k in REJECTION_COLUMNS
        },
        "accounting": "OK" if frame_count == accepted + rejected + errors else "INCONSISTENT",
    }


def collect(db: Path) -> dict:
    """Query only explicitly named aggregated tables; no file writes."""
    if not db.is_file():
        return {"status": "unavailable", "reason": "DATABASE_MISSING"}
    try:
        conn = sqlite3.connect(db.resolve().as_uri() + "?mode=ro", uri=True, timeout=8)
    except (sqlite3.Error, OSError, ValueError):
        return {"status": "unavailable", "reason": "DATABASE_UNREADABLE"}
    try:
        conn.execute("PRAGMA query_only=ON")
        version_row = conn.execute("SELECT v FROM meta WHERE k='schema_version'").fetchone()
        if version_row is None or str(version_row[0]) != "2":
            return {"status": "unavailable", "reason": "SCHEMA_NOT_V2"}
        markers = {}
        for name in ("ais_zone_tracking_since", "ais_intake_tracking_since"):
            row = conn.execute("SELECT v FROM meta WHERE k=?", (name,)).fetchone()
            markers[name] = row[0] if row else None
        intake_table = conn.execute(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='ais_intake_day'"
        ).fetchone() is not None
        rows = conn.execute(
            "SELECT " + ",".join(AGGREGATE_COLUMNS) +
            " FROM day_stats ORDER BY day DESC LIMIT ?", (MAX_DAYS,),
        ).fetchall()
        days = []
        for row in reversed(rows):
            stats = dict(zip(AGGREGATE_COLUMNS, row))
            day = stats["day"]
            if not isinstance(day, str):
                return {"status": "unavailable", "reason": "INVALID_AGGREGATE"}
            zone_phase = _tracking_phase(day, markers["ais_zone_tracking_since"])
            intake_phase = _tracking_phase(day, markers["ais_intake_tracking_since"])
            day_item = {
                "day": day,
                "accepted_positions_total": int(stats["ais_position_messages"]),
                "accepted_static_total": int(stats["ais_static_messages"]),
                "zone_message_counts": {
                    name: int(stats[f"ais_zone_{name.lower()}"]) for name in ("W", "M", "E")
                },
                "zone_unique_vessels": {
                    name: int(stats[f"ais_vessels_{name.lower()}"]) for name in ("W", "M", "E")
                },
                "zone_tracking_phase": zone_phase,
                "coarse_crossings": int(stats["ais_crossings_all"]),
                "tanker_confirmed_crossings": int(stats["ais_crossings_tanker"]),
                "ais_connected_seconds": round(float(stats["ais_connected_seconds"]), 2),
                "ais_disconnects": int(stats["ais_disconnects"]),
                "adsb_snapshots": int(stats["adsb_ok"]),
                "opensky_snapshots": int(stats["opensky_ok"]),
                "source_errors": int(stats["ais_disconnects"]) +
                    int(stats["adsb_errors"]) + int(stats["opensky_errors"]),
                "intake_tracking_phase": intake_phase,
                "intake": _intake(conn, day) if intake_table else None,
            }
            days.append(day_item)
        return {
            "status": "succeeded",
            "source": "AIRSEA_MONITOR_SHADOW",
            "schema_version": 2,
            "read_only": True,
            "as_of_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "zone_tracking_since_utc": markers["ais_zone_tracking_since"],
            "intake_tracking_since_utc": markers["ais_intake_tracking_since"],
            "days": days,
            "interpretation": "RECEPTION_OBSERVATIONS_NOT_PHYSICAL_TRAFFIC",
        }
    except (sqlite3.Error, ValueError, TypeError, OverflowError):
        return {"status": "unavailable", "reason": "AGGREGATE_QUERY_FAILED"}
    finally:
        conn.close()


def main() -> int:
    # No user/remote-supplied path, filter, SQL, filename, query or arguments.
    if len(sys.argv) != 1:
        print(json.dumps({"status": "unavailable", "reason": "NO_ARGUMENTS_ALLOWED"}))
        return 1
    local = os.environ.get("LOCALAPPDATA")
    if not local:
        print(json.dumps({"status": "unavailable", "reason": "HOST_PROFILE_UNKNOWN"}))
        return 1
    db = Path(local) / "MarketObservationPilot" / "Data" / "pilot.sqlite"
    result = collect(db)
    print(json.dumps(result, separators=(",", ":"), allow_nan=False))
    return 0 if result["status"] == "succeeded" else 1


if __name__ == "__main__":
    raise SystemExit(main())
