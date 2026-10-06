import Foundation

@main
struct ReleaseSignatureTests {
    static func main() throws {
        let digest = CommandLine.arguments[1]
        let signature = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        try ReleaseSignature.verify(digest: digest, signature: signature)
        for invalid in [Data(), Data(repeating: 0, count: 384), Data(signature.dropLast())] {
            do {
                try ReleaseSignature.verify(digest: digest, signature: invalid)
                fatalError("Invalid signature was accepted")
            } catch { }
        }
        do {
            try ReleaseSignature.verify(digest: String(repeating: "0", count: 64), signature: signature)
            fatalError("Altered release was accepted")
        } catch { }
        print("Publisher signature: valid accepted; missing, malformed, altered rejected")
    }
}
