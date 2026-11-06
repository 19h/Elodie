import Foundation

/// The vault's key as text, for keeping somewhere safe and for bringing back later.
public enum RecoveryKey {
    /// In groups that are easy to copy accurately.
    public static func text(for key: Data) -> String {
        let hex = key.map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 8).map { start in
            let from = hex.index(hex.startIndex, offsetBy: start)
            let to = hex.index(from, offsetBy: min(8, hex.count - start))
            return String(hex[from..<to])
        }.joined(separator: "-")
    }

    /// Finds a key in what someone pasted or in a saved file. A saved file has words around
    /// the key, and people retype keys with odd spacing, so this looks for 32 bytes of hex
    /// anywhere, in the form it was saved or with the separators removed.
    public static func parse(_ text: String) -> Data? {
        let hexDigits = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        var run = ""
        for character in text {
            let scalars = String(character).unicodeScalars
            if scalars.allSatisfy(hexDigits.contains) {
                run.append(character)
                if run.count == 64 { return data(fromHex: run) }
            } else if character == "-" || character == " " || character == "\n" || character == "\r" || character == "\t" {
                continue
            } else {
                // A word that isn't hex ends whatever came before it.
                run = ""
            }
        }
        return nil
    }

    private static func data(fromHex hex: String) -> Data? {
        var bytes = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}
