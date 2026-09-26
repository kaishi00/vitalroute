"""Payload validation for the VitalRoute receiver.

Implements contract v3 (see API.md): one change-batch payload whose records
are envelopes (id, metric, kind, dates, source, metadata, data) carrying a
strongly typed ``data`` payload discriminated by ``data.type``.

The receiver deliberately does NOT know individual HealthKit metrics: the
iOS client owns the metric catalog, so ``metric`` is only shape-checked and
any catalog value is accepted. What the receiver does enforce:

- schema version and exact payload shape,
- envelope shape (exact key sets, UUID id, ISO 8601 dates),
- a known record ``kind``,
- the correct typed ``data`` shape for that kind (unknown ``type``, wrong
  fields for the kind, or ``data.type`` != ``kind`` all fail loudly),
- size and structural safety limits.

Every function raises ValidationError with a machine-readable code and a
safe, payload-free message.
"""

import datetime
import json
import math
import re
import uuid

SUPPORTED_SCHEMA_VERSION = 3
SUPPORTED_API_VERSION = 3
SERVICE_NAME = "vitalroute-receiver"
RECEIVER_CAPABILITIES = ("additions", "deletions")

# The record kinds the receiver understands structurally. An unknown kind is
# rejected so contract drift fails loudly instead of storing opaque blobs.
RECORD_KINDS = frozenset(
    {
        "quantity",
        "category",
        "correlation",
        "workout",
        "activitySummary",
        "series",
        "electrocardiogram",
        "clinical",
    }
)

DEFAULT_MAX_BODY_BYTES = 10 * 1024 * 1024
DEFAULT_MAX_RECORDS_PER_BATCH = 500

# Metrics are client-owned identifiers, not a receiver-side allowlist. The
# pattern keeps them safe to store, index, and group: short, single-token,
# no whitespace or path/SQL-style surprises.
_METRIC_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
_MAX_METRIC_LENGTH = 64

_MAX_UNIT_LENGTH = 64
_MAX_NAME_LENGTH = 256
_MAX_METADATA_ENTRIES = 32
_MAX_METADATA_KEY_LENGTH = 64
_MAX_METADATA_VALUE_LENGTH = 512

# Per-kind structural limits. They bound stored-row size regardless of the
# body limit so one record can never dominate the database.
_MAX_CORRELATION_COMPONENTS = 8
_MAX_SERIES_CHANNELS = 16
_MAX_SERIES_POINTS_PER_CHUNK = 2048
_MAX_CHANNEL_NAME_LENGTH = 32
_MAX_SHORT_STRING_LENGTH = 64
_MAX_WORKOUT_ACTIVITY_LENGTH = 64
_MAX_FHIR_IDENTIFIER_LENGTH = 256
_MAX_FHIR_DEPTH = 32
_MAX_FHIR_NODES = 4096
_MAX_DATA_JSON_BYTES = 1024 * 1024

_V3_TOP_LEVEL_KEYS = frozenset({"schemaVersion", "createdAt", "batchId", "changes"})
_CHANGE_KEYS = frozenset({"kind"})
_UPSERT_KEYS = frozenset({"record"})
_DELETE_KEYS = frozenset({"id", "metric", "startDate", "endDate"})

_RECORD_REQUIRED_KEYS = frozenset(
    {"id", "metric", "kind", "startDate", "endDate", "metadata", "data"}
)
# Optional string fields: may be absent (the common Swift JSONEncoder
# spelling of null) or present with null or a string.
_RECORD_OPTIONAL_KEYS = frozenset({"sourceName", "deviceName"})

_UUID_PATTERN = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)
_CHANNEL_NAME_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$")
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


def parse_metric(value, where):
    """Shape-checks a client-owned metric identifier (no allowlist)."""
    if not isinstance(value, str) or not _METRIC_PATTERN.match(value):
        raise ValidationError(
            "invalid_metric",
            "%s has an invalid metric identifier." % where,
        )
    return value


def _require_string(value, where, max_length):
    if not isinstance(value, str) or not value or len(value) > max_length:
        raise ValidationError(
            "invalid_record",
            "%s must be a non-empty string of at most %d characters."
            % (where, max_length),
        )
    return value


def _require_optional_string(value, where, max_length=_MAX_NAME_LENGTH):
    if value is None:
        return None
    if not isinstance(value, str) or len(value) > max_length:
        raise ValidationError(
            "invalid_record",
            "%s must be null or a string of at most %d characters."
            % (where, max_length),
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


def _require_finite_number(value, where):
    """A JSON number that is not bool, NaN, or Infinity.

    json.loads yields float('inf') for overflowing literals like 1e999
    without ever calling parse_constant, so finiteness is checked here at
    every numeric site rather than only at body decode time.
    """
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValidationError(
            "invalid_record_data", "%s must be a number." % where
        )
    if not math.isfinite(value):
        raise ValidationError(
            "invalid_record_data", "%s must be a finite number." % where
        )
    return value


def _require_non_negative_int(value, where, maximum):
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValidationError("invalid_record_data", "%s must be an integer." % where)
    if value < 0 or value > maximum:
        raise ValidationError(
            "invalid_record_data",
            "%s must be an integer between 0 and %d." % (where, maximum),
        )
    return value


def _require_keys(data, required, optional, where):
    keys = set(data)
    unknown = keys - required - optional
    missing = required - keys
    if unknown or missing:
        raise ValidationError(
            "invalid_record_data",
            "%s has a field set that does not match its type." % where,
        )


# ---- typed data payloads ---------------------------------------------------
#
# Each validator takes the decoded data object (with data["type"] already
# verified against the envelope kind) and returns the canonical object that
# is stored as data_json. Unknown fields are rejected rather than ignored so
# contract drift fails loudly.


def _validate_quantity_data(data, where):
    _require_keys(data, {"type", "value", "unit"}, set(), where)
    _require_finite_number(data["value"], "%s value" % where)
    _require_string(data["unit"], "%s unit" % where, _MAX_UNIT_LENGTH)
    return {"type": "quantity", "value": data["value"], "unit": data["unit"]}, None


def _validate_category_data(data, where):
    _require_keys(data, {"type", "value"}, {"name"}, where)
    if isinstance(data["value"], bool) or not isinstance(data["value"], int):
        raise ValidationError(
            "invalid_record_data", "%s value must be an integer." % where
        )
    if data["value"] < 0 or data["value"] > 2**31 - 1:
        raise ValidationError(
            "invalid_record_data", "%s value is out of range." % where
        )
    name = _require_optional_string(
        data.get("name"), "%s name" % where, _MAX_SHORT_STRING_LENGTH
    )
    canonical = {"type": "category", "value": data["value"]}
    if name is not None:
        canonical["name"] = name
    return canonical, None


def _validate_correlation_data(data, where):
    _require_keys(data, {"type", "components"}, set(), where)
    components = data["components"]
    if not isinstance(components, list) or not (
        1 <= len(components) <= _MAX_CORRELATION_COMPONENTS
    ):
        raise ValidationError(
            "invalid_record_data",
            "%s components must be an array of 1 to %d entries."
            % (where, _MAX_CORRELATION_COMPONENTS),
        )
    canonical_components = []
    for index, component in enumerate(components):
        component_where = "%s component %d" % (where, index)
        if not isinstance(component, dict):
            raise ValidationError(
                "invalid_record_data",
                "%s must be an object." % component_where,
            )
        _require_keys(
            component, {"metric", "value", "unit"}, set(), component_where
        )
        canonical_components.append(
            {
                "metric": parse_metric(
                    component["metric"], "%s metric" % component_where
                ),
                "value": _require_finite_number(
                    component["value"], "%s value" % component_where
                ),
                "unit": _require_string(
                    component["unit"],
                    "%s unit" % component_where,
                    _MAX_UNIT_LENGTH,
                ),
            }
        )
    return {"type": "correlation", "components": canonical_components}, None


def _validate_workout_data(data, where):
    _require_keys(
        data,
        {"type", "activityType", "activityTypeRawValue", "duration"},
        {"totalEnergyKilocalories", "totalDistanceMeters"},
        where,
    )
    _require_string(
        data["activityType"],
        "%s activityType" % where,
        _MAX_WORKOUT_ACTIVITY_LENGTH,
    )
    _require_non_negative_int(
        data["activityTypeRawValue"],
        "%s activityTypeRawValue" % where,
        2**31 - 1,
    )
    duration = _require_finite_number(data["duration"], "%s duration" % where)
    if duration < 0:
        raise ValidationError(
            "invalid_record_data", "%s duration must not be negative." % where
        )
    canonical = {
        "type": "workout",
        "activityType": data["activityType"],
        "activityTypeRawValue": data["activityTypeRawValue"],
        "duration": duration,
    }
    for field in ("totalEnergyKilocalories", "totalDistanceMeters"):
        if field in data and data[field] is not None:
            value = _require_finite_number(data[field], "%s %s" % (where, field))
            if value < 0:
                raise ValidationError(
                    "invalid_record_data",
                    "%s %s must not be negative." % (where, field),
                )
            canonical[field] = value
    return canonical, None


_ACTIVITY_SUMMARY_NUMERIC_FIELDS = (
    "activeEnergyBurnedKilocalories",
    "activeEnergyBurnedGoalKilocalories",
    "exerciseTimeMinutes",
    "exerciseTimeGoalMinutes",
    "standHours",
    "standHoursGoal",
    "distanceWalkingRunningMeters",
    "distanceWalkingRunningGoalMeters",
)


def _validate_activity_summary_data(data, where):
    _require_keys(
        data, {"type"}, set(_ACTIVITY_SUMMARY_NUMERIC_FIELDS) | {"dateComponentsUTC"}, where
    )
    canonical = {"type": "activitySummary"}
    for field in _ACTIVITY_SUMMARY_NUMERIC_FIELDS:
        if field in data and data[field] is not None:
            value = _require_finite_number(data[field], "%s %s" % (where, field))
            if value < 0:
                raise ValidationError(
                    "invalid_record_data",
                    "%s %s must not be negative." % (where, field),
                )
            canonical[field] = value
    if "dateComponentsUTC" in data and data["dateComponentsUTC"] is not None:
        canonical["dateComponentsUTC"] = _require_string(
            data["dateComponentsUTC"],
            "%s dateComponentsUTC" % where,
            _MAX_SHORT_STRING_LENGTH,
        )
    return canonical, None


def _validate_series_data(data, where):
    _require_keys(
        data,
        {"type", "seriesType", "seriesID", "chunkIndex", "channels", "points"},
        {"parentID"},
        where,
    )
    _require_string(
        data["seriesType"], "%s seriesType" % where, _MAX_SHORT_STRING_LENGTH
    )
    series_id = parse_record_id(data["seriesID"], "%s seriesID" % where)
    parent_id = None
    if data.get("parentID") is not None:
        parent_id = parse_record_id(data["parentID"], "%s parentID" % where)
    chunk_index = _require_non_negative_int(
        data["chunkIndex"], "%s chunkIndex" % where, 1_000_000
    )
    channels = data["channels"]
    if not isinstance(channels, list) or not (
        1 <= len(channels) <= _MAX_SERIES_CHANNELS
    ):
        raise ValidationError(
            "invalid_record_data",
            "%s channels must be an array of 1 to %d names."
            % (where, _MAX_SERIES_CHANNELS),
        )
    for index, channel in enumerate(channels):
        if not isinstance(channel, str) or not _CHANNEL_NAME_PATTERN.match(channel):
            raise ValidationError(
                "invalid_record_data",
                "%s channel %d has an invalid name." % (where, index),
            )
    points = data["points"]
    if (
        not isinstance(points, list)
        or not 1 <= len(points) <= _MAX_SERIES_POINTS_PER_CHUNK
    ):
        raise ValidationError(
            "invalid_record_data",
            "%s points must be an array of 1 to %d rows."
            % (where, _MAX_SERIES_POINTS_PER_CHUNK),
        )
    width = len(channels)
    canonical_points = []
    for row_index, row in enumerate(points):
        if not isinstance(row, list) or len(row) != width:
            raise ValidationError(
                "invalid_record_data",
                "%s point %d must have exactly %d values."
                % (where, row_index, width),
            )
        canonical_points.append(
            [
                _require_finite_number(
                    value, "%s point %d" % (where, row_index)
                )
                for value in row
            ]
        )
    canonical = {
        "type": "series",
        "seriesType": data["seriesType"],
        "seriesID": series_id,
        "chunkIndex": chunk_index,
        "channels": list(channels),
        "points": canonical_points,
    }
    if parent_id is not None:
        canonical["parentID"] = parent_id
    return canonical, parent_id


_ECG_STRING_FIELDS = ("classification", "symptomStatus")


def _validate_electrocardiogram_data(data, where):
    _require_keys(
        data,
        {"type", "classification"},
        {
            "classificationRawValue",
            "symptomStatus",
            "symptomStatusRawValue",
            "averageHeartRate",
            "samplingFrequency",
            "voltageSeriesID",
            "voltageChunkCount",
        },
        where,
    )
    _require_string(
        data["classification"],
        "%s classification" % where,
        _MAX_SHORT_STRING_LENGTH,
    )
    canonical = {"type": "electrocardiogram", "classification": data["classification"]}
    if "classificationRawValue" in data and data["classificationRawValue"] is not None:
        _require_non_negative_int(
            data["classificationRawValue"],
            "%s classificationRawValue" % where,
            2**31 - 1,
        )
        canonical["classificationRawValue"] = data["classificationRawValue"]
    if "symptomStatus" in data and data["symptomStatus"] is not None:
        canonical["symptomStatus"] = _require_string(
            data["symptomStatus"], "%s symptomStatus" % where, _MAX_SHORT_STRING_LENGTH
        )
    if (
        "symptomStatusRawValue" in data
        and data["symptomStatusRawValue"] is not None
    ):
        _require_non_negative_int(
            data["symptomStatusRawValue"],
            "%s symptomStatusRawValue" % where,
            2**31 - 1,
        )
        canonical["symptomStatusRawValue"] = data["symptomStatusRawValue"]
    if "averageHeartRate" in data and data["averageHeartRate"] is not None:
        value = _require_finite_number(
            data["averageHeartRate"], "%s averageHeartRate" % where
        )
        if value < 0:
            raise ValidationError(
                "invalid_record_data",
                "%s averageHeartRate must not be negative." % where,
            )
        canonical["averageHeartRate"] = value
    if "samplingFrequency" in data and data["samplingFrequency"] is not None:
        value = _require_finite_number(
            data["samplingFrequency"], "%s samplingFrequency" % where
        )
        if value <= 0:
            raise ValidationError(
                "invalid_record_data",
                "%s samplingFrequency must be positive." % where,
            )
        canonical["samplingFrequency"] = value
    if "voltageSeriesID" in data and data["voltageSeriesID"] is not None:
        canonical["voltageSeriesID"] = parse_record_id(
            data["voltageSeriesID"], "%s voltageSeriesID" % where
        )
    if "voltageChunkCount" in data and data["voltageChunkCount"] is not None:
        _require_non_negative_int(
            data["voltageChunkCount"], "%s voltageChunkCount" % where, 1_000_000
        )
        canonical["voltageChunkCount"] = data["voltageChunkCount"]
    return canonical, None


def _validate_fhir_value(value, where):
    """Structural check of a FHIR JSON value; returns its node count.

    Values are preserved verbatim (objects, arrays, strings, numbers,
    booleans, null). Only size, depth, and finiteness are enforced so the
    receiver never has to understand FHIR to store it faithfully.

    Iterative by design: adversarially deep input must hit the depth limit,
    not Python's recursion limit.
    """
    total = 0
    # (value, depth) worklist; the container check never recurses.
    stack = [(value, 0)]
    while stack:
        current, depth = stack.pop()
        if depth > _MAX_FHIR_DEPTH:
            raise ValidationError(
                "invalid_record_data", "%s is nested too deeply." % where
            )
        total += 1
        if total > _MAX_FHIR_NODES:
            raise ValidationError(
                "invalid_record_data",
                "%s exceeds the structural node budget." % where,
            )
        if current is None or isinstance(current, (bool, str)):
            continue
        if isinstance(current, (int, float)):
            if not math.isfinite(current):
                raise ValidationError(
                    "invalid_record_data",
                    "%s contains a non-finite number." % where,
                )
            continue
        if isinstance(current, list):
            stack.extend((item, depth + 1) for item in reversed(current))
            continue
        if isinstance(current, dict):
            for key, item in current.items():
                if not isinstance(key, str) or not key or len(key) > 256:
                    raise ValidationError(
                        "invalid_record_data",
                        "%s has an invalid object key." % where,
                    )
            stack.extend(
                (item, depth + 1) for item in reversed(list(current.values()))
            )
            continue
        raise ValidationError(
            "invalid_record_data", "%s contains an unsupported value." % where
        )
    return total


def _validate_clinical_data(data, where):
    _require_keys(
        data,
        {"type", "fhirType", "fhirResource"},
        {"fhirIdentifier"},
        where,
    )
    _require_string(data["fhirType"], "%s fhirType" % where, _MAX_SHORT_STRING_LENGTH)
    resource = data["fhirResource"]
    if not isinstance(resource, dict):
        raise ValidationError(
            "invalid_record_data",
            "%s fhirResource must be a JSON object." % where,
        )
    _validate_fhir_value(resource, "%s fhirResource" % where)
    canonical = {
        "type": "clinical",
        "fhirType": data["fhirType"],
        "fhirResource": resource,
    }
    if "fhirIdentifier" in data and data["fhirIdentifier"] is not None:
        canonical["fhirIdentifier"] = _require_optional_string(
            data["fhirIdentifier"],
            "%s fhirIdentifier" % where,
            _MAX_FHIR_IDENTIFIER_LENGTH,
        )
    return canonical, None


_DATA_VALIDATORS = {
    "quantity": _validate_quantity_data,
    "category": _validate_category_data,
    "correlation": _validate_correlation_data,
    "workout": _validate_workout_data,
    "activitySummary": _validate_activity_summary_data,
    "series": _validate_series_data,
    "electrocardiogram": _validate_electrocardiogram_data,
    "clinical": _validate_clinical_data,
}


def canonicalize_data(data, kind, where):
    """Validates and canonicalizes a typed data payload for a kind.

    Returns (canonical_data_object, parent_id). parent_id is present only
    for series chunks that declare a parent record.
    """
    if not isinstance(data, dict):
        raise ValidationError(
            "invalid_record_data", "%s data must be an object." % where
        )
    data_type = data.get("type")
    if data_type not in RECORD_KINDS:
        raise ValidationError(
            "unknown_record_data_type",
            "%s data has an unknown type." % where,
        )
    if data_type != kind:
        raise ValidationError(
            "invalid_record_data",
            "%s data type does not match the record kind." % where,
        )
    # Every kind validator returns (canonical_object, extra) where extra is
    # the parent reference for series chunks and None otherwise.
    canonical, parent_id = _DATA_VALIDATORS[kind](data, where)
    return canonical, parent_id


# ---- payload validation ----------------------------------------------------


def validate_change_payload(payload, max_changes):
    """Validates a schemaVersion 3 change batch.

    Returns (batch_created_at_text, [PreparedChange, ...]).
    """
    if not isinstance(payload, dict):
        raise ValidationError("invalid_json", "The request body must be a JSON object.")
    if set(payload) != _V3_TOP_LEVEL_KEYS:
        raise ValidationError(
            "invalid_payload",
            "The payload must contain exactly schemaVersion, createdAt, batchId, and changes.",
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


class PreparedRecord:
    """One validated record, ready for storage. Attribute access over
    positional tuples: the storage layer reads these by name, so inserting
    a field cannot silently shift columns."""

    __slots__ = (
        "id",
        "metric",
        "kind",
        "start_date",
        "end_date",
        "source_name",
        "device_name",
        "metadata_json",
        "data_json",
        "parent_id",
    )

    def __init__(self, id, metric, kind, start_date, end_date,
                 source_name, device_name, metadata_json, data_json, parent_id):
        self.id = id
        self.metric = metric
        self.kind = kind
        self.start_date = start_date
        self.end_date = end_date
        self.source_name = source_name
        self.device_name = device_name
        self.metadata_json = metadata_json
        self.data_json = data_json
        self.parent_id = parent_id


class PreparedChange:
    """One validated change, ready for transactional application."""

    def __init__(self, kind, record_id, metric, record=None, dates=None):
        self.kind = kind  # "upsert" | "delete"
        self.record_id = record_id
        self.metric = metric
        self.record = record  # PreparedRecord for upserts
        self.dates = dates  # (start_text, end_text) for deletes


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
            "%s must contain exactly the contract envelope fields." % where,
        )

    metric = parse_metric(record["metric"], where)

    record_kind = record["kind"]
    if not isinstance(record_kind, str) or record_kind not in RECORD_KINDS:
        raise ValidationError(
            "unknown_record_kind", "%s has an unknown record kind." % where
        )

    start_date = parse_timestamp(record["startDate"], "%s startDate" % where)
    end_date = parse_timestamp(record["endDate"], "%s endDate" % where)
    if end_date < start_date:
        raise ValidationError(
            "invalid_record", "%s endDate must not precede startDate." % where
        )

    metadata = _require_metadata(record["metadata"], where)

    canonical_data, parent_id = canonicalize_data(
        record["data"], record_kind, "%s data" % where
    )
    try:
        data_json = json_dumps_sorted(canonical_data)
    except (TypeError, ValueError):
        raise ValidationError(
            "invalid_record_data", "%s data is not JSON-serializable." % where
        )
    if len(data_json) > _MAX_DATA_JSON_BYTES:
        raise ValidationError(
            "record_too_large",
            "%s data exceeds the %d byte limit."
            % (where, _MAX_DATA_JSON_BYTES),
        )

    return PreparedRecord(
        id=parse_record_id(record["id"], "%s id" % where),
        metric=metric,
        kind=record_kind,
        start_date=format_timestamp_utc(start_date),
        end_date=format_timestamp_utc(end_date),
        source_name=_require_optional_string(record.get("sourceName"), "%s sourceName" % where),
        device_name=_require_optional_string(record.get("deviceName"), "%s deviceName" % where),
        metadata_json=json_dumps_sorted(metadata),
        data_json=data_json,
        parent_id=parent_id,
    )


def json_dumps_sorted(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False)


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
        prepared_record = _validate_record(record, index)
        return PreparedChange("upsert", prepared_record.id, prepared_record.metric, record=prepared_record)
    if kind == "delete":
        if _DELETE_KEYS != keys - _CHANGE_KEYS:
            raise ValidationError(
                "invalid_record", "%s delete must contain exactly id, metric, startDate, endDate." % where
            )
        record_id = parse_record_id(change["id"], "%s id" % where)
        metric = parse_metric(change["metric"], where)
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
