import Foundation
import Network
import CryptoKit
import Security

/// 配對碼：20 個 Base32 字元（約 100 bits 熵），顯示為 XXXXX-XXXXX-XXXXX-XXXXX。
/// 配對碼經 HKDF-SHA256 衍生出 256-bit 金鑰，作為 TLS 的 Pre-Shared Key。
/// 沒有配對碼的人無法完成 TLS 交握，所有畫面、鍵盤、滑鼠資料都經 AES-256-GCM 加密。
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

enum SecureTransport {
    /// 建立兩端共用的連線參數：TCP(keepalive) + TLS(PSK, AES-256-GCM) + 自訂訊息分框
    static func parameters(pairingCode: String) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 6

        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        let key = PairingCode.preSharedKey(for: pairingCode)
        let keyData = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data(RemoteConstants.pskIdentity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(sec, keyData as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(
            sec, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_256_GCM_SHA384))!)
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)

        let params = NWParameters(tls: tls, tcp: tcp)
        params.includePeerToPeer = true
        params.serviceClass = .interactiveVideo
        let framer = NWProtocolFramer.Options(definition: RemoteFramer.definition)
        params.defaultProtocolStack.applicationProtocols.insert(framer, at: 0)
        return params
    }
}
