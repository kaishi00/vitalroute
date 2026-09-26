import Foundation

/// A typed recursive JSON value, used where HealthKit's payload is
/// inherently open-ended: clinical FHIR resources.
///
/// This is the one deliberate exception to VitalRoute's "no type-erased
/// data" rule, and it is not type erasure: every node is one of six
/// explicit cases, encoding is deterministic (objects sort their keys via
/// the shared encoder), and decoding fails loudly on anything else. It
/// exists so a FHIR document is preserved *structurally* — never flattened
/// into strings — without requiring the app to model every FHIR resource
/// type.
///
/// Number fidelity note: JSON has one number spelling, so a decoded
/// integral value always comes back as `.int` — `double(2.0)` encodes as
/// `2` and re-decodes as `.int(2)`. This only matters if the client ever
/// re-decodes its own FHIR output; the receiver stores the encoded bytes.
enum FHIRJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([FHIRJSON])
    case object([String: FHIRJSON])
}

extension FHIRJSON: Codable {
    private enum CodingKeys: String, CodingKey {
        case null = "null"
        case bool
        case int
        case double
        case string
        case array
        case object
    }

    // Tagged encoding rather than raw JSON passthrough: the wire format
    // must stay deterministic and self-describing, and the receiver's
    // clinical validator expects `fhirResource` to decode back to exactly
    // this shape. The receiver validates the *decoded object* form below.
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            // JSONEncoder refuses NaN/Infinity; a non-finite double is a
            // programmer error that must surface, not round-trip.
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let values):
            try container.encode(values)
        case .object(let values):
            try container.encode(values)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            // Non-finite numbers are invalid FHIR values; catching them at
            // decode keeps the failure at the edge instead of mid-encode.
            guard value.isFinite else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Non-finite numbers are not valid FHIR values."
                )
            }
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([FHIRJSON].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: FHIRJSON].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value in FHIR resource."
            )
        }
    }
}
