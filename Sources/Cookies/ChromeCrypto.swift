import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
#endif
import Crypto

enum ChromeCrypto {
    static func deriveAes128CbcKey(password: String, iterations: Int) -> Data {
        pbkdf2SHA1(password: password, salt: Data("saltysalt".utf8), iterations: UInt32(iterations), keyLength: 16)
    }

    static func decryptAes128Cbc(
        encryptedValue: Data,
        keys: [Data],
        stripHashPrefix: Bool,
        treatUnknownPrefixAsPlaintext: Bool = true
    ) -> String? {
        guard encryptedValue.count >= 3 else { return nil }
        let prefix = String(data: encryptedValue.prefix(3), encoding: .utf8) ?? ""
        let hasVersion = prefix.range(of: #"^v\d\d$"#, options: .regularExpression) != nil
        if !hasVersion {
            if !treatUnknownPrefixAsPlaintext { return nil }
            return decodeValue(encryptedValue, stripHashPrefix: false)
        }
        let ciphertext = Data(encryptedValue.dropFirst(3))
        if ciphertext.isEmpty { return "" }
        for key in keys {
            if let plain = aes128CbcDecrypt(ciphertext: ciphertext, key: key),
               let decoded = decodeValue(plain, stripHashPrefix: stripHashPrefix)
            {
                return decoded
            }
        }
        return nil
    }

    static func decryptAes256Gcm(encryptedValue: Data, key: Data, stripHashPrefix: Bool) -> String? {
        guard encryptedValue.count >= 3 else { return nil }
        let prefix = String(data: encryptedValue.prefix(3), encoding: .utf8) ?? ""
        guard prefix.range(of: #"^v\d\d$"#, options: .regularExpression) != nil else { return nil }
        let payload = encryptedValue.dropFirst(3)
        guard payload.count >= 28 else { return nil }
        let nonce = Data(payload.prefix(12))
        let tag = Data(payload.suffix(16))
        let ciphertext = Data(payload.dropFirst(12).dropLast(16))
        do {
            let sealed = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonce),
                ciphertext: ciphertext,
                tag: tag
            )
            let plain = try AES.GCM.open(sealed, using: SymmetricKey(data: key))
            return decodeValue(plain, stripHashPrefix: stripHashPrefix)
        } catch {
            return nil
        }
    }

    private static func aes128CbcDecrypt(ciphertext: Data, key: Data) -> Data? {
        guard key.count == 16, !ciphertext.isEmpty, ciphertext.count % 16 == 0 else { return nil }
        var out = Data(count: ciphertext.count)
        var outLen: Int = 0
        let iv = [UInt8](repeating: 0x20, count: 16)
        let status: Int32 = out.withUnsafeMutableBytes { outPtr in
            ciphertext.withUnsafeBytes { cipherPtr in
                key.withUnsafeBytes { keyPtr in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        0,
                        keyPtr.baseAddress,
                        key.count,
                        iv,
                        cipherPtr.baseAddress,
                        ciphertext.count,
                        outPtr.baseAddress,
                        ciphertext.count,
                        &outLen
                    )
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.count = outLen
        return removePkcs7(out)
    }

    private static func removePkcs7(_ value: Data) -> Data {
        guard let pad = value.last, pad > 0, pad <= 16, value.count >= Int(pad) else { return value }
        return Data(value.dropLast(Int(pad)))
    }

    private static func decodeValue(_ value: Data, stripHashPrefix: Bool) -> String? {
        let bytes = stripHashPrefix && value.count >= 32 ? value.dropFirst(32) : value[...]
        return String(data: Data(bytes), encoding: .utf8)
    }

    static func pbkdf2SHA1(password: String, salt: Data, iterations: UInt32, keyLength: Int) -> Data {
        var derived = Data(count: keyLength)
        let passwordData = Data(password.utf8)
        let result = derived.withUnsafeMutableBytes { derivedPtr in
            passwordData.withUnsafeBytes { passPtr in
                salt.withUnsafeBytes { saltPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passPtr.bindMemory(to: Int8.self).baseAddress,
                        passwordData.count,
                        saltPtr.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        iterations,
                        derivedPtr.bindMemory(to: UInt8.self).baseAddress,
                        keyLength
                    )
                }
            }
        }
        precondition(result == kCCSuccess)
        return derived
    }
}
