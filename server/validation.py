"""Payload validation for the VitalRoute receiver.

Implements contracts v1 and v2 (see API.md). Every function raises
ValidationError with a machine-readable code and a safe, payload-free
message.
"""

import datetime
import math
import re
import uuid

SUPPORTED_SCHEMA_VERSION = 1
SUPPORTED_SCHEMA_VERSION_MAX = 2
SUPPORTED_API_VERSION = 2
SERVICE_NAME = "vitalroute-receiver"
RECEIVER_CAPABILITIES = ("additions", "deletions")

ALLOWED_METRICS = frozenset(
    {
        "steps",
        "heartRate",
        "restingHeartRate",
        "heartRateVariability",
        "sleep",
        "activeEnergy",
        "workouts",
    }
)

DEFAULT_MAX_BODY_BYTES = 10 * 1024 * 1024
DEFAULT_MAX_RECORDS_PER_BATCH = 500

_MAX_UNIT_LENGTH = 64
_MAX_NAME_LENGTH = 256
_MAX_METADATA_ENTRIES = 32
_MAX_METADATA_KEY_LENGTH = 64
_MAX_METADATA_VALUE_LENGTH = 512

_TOP_LEVEL_KEYS = frozenset({"schemaVersion", "createdAt", "records"})
_RECORD_REQUIRED_KEYS = frozenset(
    {
        "id",
        "metric",
        "value",
        "unit",
        "startDate",
        "endDate",
        "metadata",
    }
)
# Optional string fields: may be absent (the common Swift JSONEncoder
# spelling of null) or present with null or a string.
_RECORD_OPTIONAL_KEYS = frozenset({"sourceName", "deviceName"})

_UUID_PATTERN = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
# ISO 8601 date-time with a mandatory UTC offset ("Z" or "+HH:MM") and
# optional fractional seconds (1-9 digits).
_TIMESTAMP_PATTERN = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$"
)


class ValidationError(Exception):
    """A contract violation with an error code and a safe message."""

    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


def parse_timestamp(value, where):
    """Parses an ISO 8601 date-time with offset; returns an aware datetime."""
    if not isinstance(value, str) or not _TIMESTAMP_PATTERN.match(value):
        raise ValidationError(
            "invalid_record",
            "%s must be an ISO 8601 date-time with a UTC offset." % where,
        )
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    offset = normalized[-6:]
    body = normalized[:-6]
    if "." in body:
        head, fraction = body.split(".", 1)
        # datetime.fromisoformat accepts 3 or 6 fractional digits in Python
        # 3.9; normalize any 1-9 digit input to microseconds.
        body = head + "." + (fraction + "000000")[:6]
    try:
        parsed = datetime.datetime.fromisoformat(body + offset)
    except ValueError:
        raise ValidationError(
            "invalid_record", "%s is not a valid date-time." % where
        )
    if parsed.tzinfo is None or parsed.tzinfo.utcoffset(parsed) is None:
        raise ValidationError(
            "invalid_record", "%s must include a UTC offset." % where
        )
    return parsed


def format_timestamp_utc(moment):
    """Formats an aware datetime as UTC with millisecond precision."""
    utc = moment.astimezone(datetime.timezone.utc)
    return utc.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (utc.microsecond // 1000)


def parse_record_id(value, where):
    if not isinstance(value, str) or not _UUID_PATTERN.match(value):
        raise ValidationError(
            "invalid_record", "%s must be a canonical UUID string." % where
        )
    return str(uuid.UUID(value)).lower()


def _require_string(value, where, max_length):
    if not isinstance(value, str) or not value or len(value) > max_length:
        raise ValidationError(
            "invalid_record",
            "%s must be a non-empty string of at most %d characters."
            % (where, max_length),
        )
    return value


def _require_optional_string(value, where):
    if value is None:
        return None
    if not isinstance(value, str) or len(value) > _MAX_NAME_LENGTH:
        raise ValidationError(
            "invalid_record",
            "%s must be null or a string of at most %d characters."
            % (where, _MAX_NAME_LENGTH),
        )
    return value


def _require_metadata(value, where):
    if not isinstance(value, dict) or len(value) > _MAX_METADATA_ENTRIES:
        raise ValidationError(
            "invalid_record",
            "%s must be an object with at most %d entries."
            % (where, _MAX_METADATA_ENTRIES),
        )
    for key, item in value.items():
        if not isinstance(key, str) or not key or len(key) > _MAX_METADATA_KEY_LENGTH:
            raise ValidationError(
                "invalid_record", "%s has an invalid metadata key." % where
            )
        if not isinstance(item, str) or len(item) > _MAX_METADATA_VALUE_LENGTH:
            raise ValidationError(
                "invalid_record",
                "%s metadata values must be strings of at most %d characters."
                % (where, _MAX_METADATA_VALUE_LENGTH),
            )
    return value


def validate_payload(payload, max_records):
    """Validates a decoded ingestion payload and returns storage tuples.

    Returns (batch_created_at_text, [(record tuple), ...]).
    """
    if not isinstance(payload, dict):
        raise ValidationError("invalid_json", "The request body must be a JSON object.")
    keys = set(payload)
    if keys != _TOP_LEVEL_KEYS:
        raise ValidationError(
            "invalid_payload",
            "The payload must contain exactly schemaVersion, createdAt, and records.",
        )

    schema_version = payload["schemaVersion"]
    if isinstance(schema_version, bool) or not isinstance(schema_version, int):
        raise ValidationError("unsupported_schema_version", "schemaVersion must be an integer.")
    if schema_version != SUPPORTED_SCHEMA_VERSION:
        raise ValidationError(
            "unsupported_schema_version",
            "Unsupported schemaVersion %s; this receiver supports %d."
            % (schema_version, SUPPORTED_SCHEMA_VERSION),
        )

    batch_created_at = parse_timestamp(payload["createdAt"], "createdAt")
    batch_created_at_text = format_timestamp_utc(batch_created_at)

    records = payload["records"]
    if not isinstance(records, list):
        raise ValidationError("invalid_payload", "records must be an array.")
    if len(records) == 0:
        raise ValidationError("empty_batch", "records must contain at least one record.")
    if len(records) > max_records:
        raise ValidationError(
            "too_many_records",
            "A batch may contain at most %d records; got %d." % (max_records, len(records)),
        )

    prepared = [
        _validate_record(record, index) for index, record in enumerate(records)
    ]
    return batch_created_at_text, prepared


def _validate_record(record, index):
    where = "record at index %d" % index
    if not isinstance(record, dict):
        raise ValidationError("invalid_record", "%s must be an object." % where)
    keys = set(record)
    unknown = keys - _RECORD_REQUIRED_KEYS - _RECORD_OPTIONAL_KEYS
    missing = _RECORD_REQUIRED_KEYS - keys
    if unknown or missing:
        raise ValidationError(
            "invalid_record",
            "%s must contain exactly the nine contract fields." % where,
        )

    metric = record["metric"]
    if not isinstance(metric, str) or metric not in ALLOWED_METRICS:
        raise ValidationError(
            "unknown_metric", "%s has an unsupported metric." % where
        )

    value = record["value"]
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValidationError("invalid_record", "%s value must be a finite number." % where)

    start_date = parse_timestamp(record["startDate"], "%s startDate" % where)
    end_date = parse_timestamp(record["endDate"], "%s endDate" % where)
    if end_date < start_date:
        raise ValidationError(
            "invalid_record", "%s endDate must not precede startDate." % where
        )

    return (
        parse_record_id(record["id"], "%s id" % where),
        metric,
        float(value),
        _require_string(record["unit"], "%s unit" % where, _MAX_UNIT_LENGTH),
        format_timestamp_utc(start_date),
        format_timestamp_utc(end_date),
        _require_optional_string(record.get("sourceName"), "%s sourceName" % where),
        _require_optional_string(record.get("deviceName"), "%s deviceName" % where),
        _require_metadata(record["metadata"], "%s metadata" % where),
    )


# ---- contract v2: additions + deletions -----------------------------------

_V2_TOP_LEVEL_KEYS = frozenset({"schemaVersion", "createdAt", "batchId", "changes"})
_CHANGE_KEYS = frozenset({"kind"})
_UPSERT_KEYS = frozenset({"record"})
_DELETE_KEYS = frozenset({"id", "metric", "startDate", "endDate"})


class PreparedChange:
    """One validated v2 change, ready for transactional application."""

    def __init__(self, kind, record_id, metric, record_tuple=None, dates=None):
        self.kind = kind  # "upsert" | "delete"
        self.record_id = record_id
        self.metric = metric
        self.record_tuple = record_tuple  # v1 record tuple for upserts
        self.dates = dates  # (start_text, end_text) for deletes


def validate_change_payload(payload, max_changes):
    """Validates a schemaVersion 2 payload.

    Returns (batch_created_at_text, [PreparedChange, ...]).
    """
    if not isinstance(payload, dict):
        raise ValidationError("invalid_json", "The request body must be a JSON object.")
    if set(payload) != _V2_TOP_LEVEL_KEYS:
        raise ValidationError(
            "invalid_payload",
            "The v2 payload must contain exactly schemaVersion, createdAt, batchId, and changes.",
        )

    schema_version = payload["schemaVersion"]
    if isinstance(schema_version, bool) or not isinstance(schema_version, int):
        raise ValidationError("unsupported_schema_version", "schemaVersion must be an integer.")
    if schema_version != 2:
        raise ValidationError(
            "unsupported_schema_version",
            "Unsupported schemaVersion %s; this receiver supports 1 and 2." % schema_version,
        )

    batch_created_at = parse_timestamp(payload["createdAt"], "createdAt")
    batch_created_at_text = format_timestamp_utc(batch_created_at)
    parse_record_id(payload["batchId"], "batchId")

    changes = payload["changes"]
    if not isinstance(changes, list):
        raise ValidationError("invalid_payload", "changes must be an array.")
    if len(changes) == 0:
        raise ValidationError("empty_batch", "changes must contain at least one change.")
    if len(changes) > max_changes:
        raise ValidationError(
            "too_many_records",
            "A batch may contain at most %d changes; got %d." % (max_changes, len(changes)),
        )

    prepared = [
        _validate_change(change, index) for index, change in enumerate(changes)
    ]
    return batch_created_at_text, prepared


def _validate_change(change, index):
    where = "change at index %d" % index
    if not isinstance(change, dict):
        raise ValidationError("invalid_record", "%s must be an object." % where)
    keys = set(change)
    if not keys >= _CHANGE_KEYS or not keys <= (_CHANGE_KEYS | _UPSERT_KEYS | _DELETE_KEYS):
        raise ValidationError(
            "invalid_record", "%s must contain kind plus the fields for that kind." % where
        )
    kind = change["kind"]
    if kind == "upsert":
        if _UPSERT_KEYS != keys - _CHANGE_KEYS:
            raise ValidationError("invalid_record", "%s upsert must contain exactly record." % where)
        record = change["record"]
        if not isinstance(record, dict):
            raise ValidationError("invalid_record", "%s record must be an object." % where)
        record_tuple = _validate_record(record, index)
        return PreparedChange("upsert", record_tuple[0], record_tuple[1], record_tuple=record_tuple)
    if kind == "delete":
        if _DELETE_KEYS != keys - _CHANGE_KEYS:
            raise ValidationError(
                "invalid_record", "%s delete must contain exactly id, metric, startDate, endDate." % where
            )
        record_id = parse_record_id(change["id"], "%s id" % where)
        metric = change["metric"]
        if not isinstance(metric, str) or metric not in ALLOWED_METRICS:
            raise ValidationError("unknown_metric", "%s has an unsupported metric." % where)
        start_date = parse_timestamp(change["startDate"], "%s startDate" % where)
        end_date = parse_timestamp(change["endDate"], "%s endDate" % where)
        if end_date < start_date:
            raise ValidationError(
                "invalid_record", "%s endDate must not precede startDate." % where
            )
        return PreparedChange(
            "delete",
            record_id,
            metric,
            dates=(format_timestamp_utc(start_date), format_timestamp_utc(end_date)),
        )
    raise ValidationError("invalid_record", "%s has an unsupported kind." % where)
