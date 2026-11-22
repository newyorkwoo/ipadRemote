import Foundation
import Network
import CryptoKit
import Security

/// 配對碼：20 個 Base32 字元（約 100 bits 熵），顯示為 XXXXX-XXXXX-XXXXX-XXXXX。
/// 配對碼經 HKDF-SHA256 衍生出 256-bit 金鑰，作為第一次配對時 TLS 的 Pre-Shared Key。
/// 配對成功後 Mac 會發給 iPad 專屬裝置金鑰，並自動更換配對碼（配對碼只能用一次）。
enum PairingCode {
    private static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") // 去掉易混淆的 I O 0 1
    static let length = 20

    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "無法產生安全亂數")
        let chars = bytes.map { alphabet[Int($0) % alphabet.count] } // 256 可被 32 整除，無偏差
        return format(String(chars))
    }

    static func normalize(_ code: String) -> String {
        let allowed = Set(alphabet)
        return String(code.uppercased().filter { allowed.contains($0) })
    }

    static func isValid(_ code: String) -> Bool {
        normalize(code).count == length
    }

    static func format(_ code: String) -> String {
        let clean = normalize(code)
        return stride(from: 0, to: clean.count, by: 5).map { start -> String in
            let s = clean.index(clean.startIndex, offsetBy: start)
            let e = clean.index(s, offsetBy: min(5, clean.count - start))
            return String(clean[s..<e])
        }.joined(separator: "-")
    }

    static func preSharedKey(for code: String) -> SymmetricKey {
        let ikm = SymmetricKey(data: Data(normalize(code).utf8))
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm,
                                      salt: Data("iPadRemote-salt-v1".utf8),
                                      info: Data("tls-psk".utf8),
                                      outputByteCount: 32)
    }
}

/// TLS 的一組 Pre-Shared Key：配對碼（只用於第一次配對）或 Mac 發給每台 iPad 的專屬裝置金鑰
struct PSKCredential: Equatable {
    var identity: String
    var key: Data

    /// 用配對碼連線（第一次配對）
    static func pairing(_ code: String) -> PSKCredential {
        PSKCredential(identity: RemoteConstants.pskIdentity,
                      key: PairingCode.preSharedKey(for: code).withUnsafeBytes { Data($0) })
    }

    /// 已配對 iPad 的專屬金鑰；Mac 移除這台 iPad 後就無法再完成交握
    static func device(id: String, key: Data) -> PSKCredential {
        PSKCredential(identity: "device:" + id, key: key)
    }

    static func newDeviceKey() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "無法產生安全亂數")
        return Data(bytes)
    }
}

enum SecureTransport {
    /// ECDHE-PSK：除了 PSK 驗證身分，每次連線另外以一次性的橢圓曲線金鑰交換產生加密金鑰（前向保密）。
    /// 即使配對碼或裝置金鑰日後外洩，也無法解開先前錄下的連線內容。
    static let cipherSuite = tls_ciphersuite_t(rawValue: UInt16(TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256))!

    static func parameters(pairingCode: String) -> NWParameters {
        parameters(credentials: [.pairing(pairingCode)])
    }

    /// 建立連線參數：TCP(keepalive) + TLS 1.2(ECDHE-PSK, ChaCha20-Poly1305) + 自訂訊息分框。
    /// 伺服器端可放多組金鑰（配對碼 + 每台已配對 iPad），依客戶端送出的 identity 選用。
    static func parameters(credentials: [PSKCredential]) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 6

        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        for credential in credentials {
            let keyData = credential.key.withUnsafeBytes { DispatchData(bytes: $0) }
            let identity = Data(credential.identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
            sec_protocol_options_add_pre_shared_key(sec, keyData as __DispatchData, identity as __DispatchData)
        }
        sec_protocol_options_append_tls_ciphersuite(sec, cipherSuite)
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_tls_tickets_enabled(sec, false)

        let params = NWParameters(tls: tls, tcp: tcp)
        params.includePeerToPeer = true
        params.serviceClass = .interactiveVideo
        let framer = NWProtocolFramer.Options(definition: RemoteFramer.definition)
        params.defaultProtocolStack.applicationProtocols.insert(framer, at: 0)
        return params
    }

    private static func tlsMetadata(_ connection: NWConnection) -> sec_protocol_metadata_t? {
        (connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata)?
            .securityProtocolMetadata
    }

    /// 實際協商出的加密套件（測試用來確認確實啟用前向保密）
    static func negotiatedCipherSuite(_ connection: NWConnection) -> tls_ciphersuite_t? {
        tlsMetadata(connection).map(sec_protocol_metadata_get_negotiated_tls_ciphersuite)
    }

    /// 裝置證明：HMAC(裝置金鑰, 這條 TLS 連線匯出的秘密值)。
    /// 綁定在這次連線上，所以無法被錄下重送；Mac 以此確認連進來的是哪一台已配對的 iPad。
    static func deviceProof(key: Data, connection: NWConnection) -> Data? {
        guard let metadata = tlsMetadata(connection) else { return nil }
        let label = "EXPORTER-iPadRemote-device-proof"
        guard let secret = label.withCString({
            sec_protocol_metadata_create_secret(metadata, strlen($0), $0, 32)
        }) else { return nil }
        let exported = Data(secret as DispatchData)
        let mac = HMAC<SHA256>.authenticationCode(for: exported, using: SymmetricKey(data: key))
        return Data(mac)
    }

    /// 固定時間比較，避免從比對時間推測內容
    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
