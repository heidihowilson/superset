import Foundation

/// The `{ "data": { "json": Payload } }` success core both the cloud-tRPC and relay/host
/// envelopes wrap. The two envelopes differ in whether they also model an error-on-200
/// sibling — the cloud list read tolerates one (#69), the relay/host read does not — so
/// only this success core is shared; each client keeps its own top-level envelope.
struct SuperJSONResult<Payload: Decodable>: Decodable {
    struct DataBox: Decodable { let json: Payload }
    let data: DataBox
}

/// Rejects a non-2xx HTTP response (or a non-HTTP response) as `AuthError.badServerResponse`
/// — the shared status gate for the cloud-tRPC and relay/host transports.
func ensureSuccessStatus(_ response: URLResponse) throws {
    guard let http = response as? HTTPURLResponse else {
        throw AuthError.badServerResponse(status: -1)
    }
    guard (200..<300).contains(http.statusCode) else {
        throw AuthError.badServerResponse(status: http.statusCode)
    }
}

/// Decodes a 2xx response body as `Payload`, honoring the undecodable-body half of the
/// `badServerResponse` contract (AuthError.swift): a body the expected type can't decode is
/// surfaced as `AuthError.badServerResponse` rather than leaking a raw `DecodingError` that
/// falls through `AuthError.userFacingMessage` to a generic message. The companion decode
/// gate to `ensureSuccessStatus` for the cloud-tRPC and relay/host transports; the status
/// mirrors the existing 2xx-but-unusable-body convention (`status: 200`).
func decodeSuccessBody<Payload: Decodable>(_ type: Payload.Type, from data: Data) throws -> Payload {
    do {
        return try JSONDecoder().decode(type, from: data)
    } catch is DecodingError {
        throw AuthError.badServerResponse(status: 200)
    }
}
