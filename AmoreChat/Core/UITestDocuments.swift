#if DEBUG
import Foundation

/// Built only for the simulator selection test. The real Files picker reads
/// these synthetic files from On My iPhone, not an injected picker callback.
enum UITestDocuments {
    static func seed() {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        do {
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            try Data("A small synthetic note.\n".utf8)
                .write(to: documents.appendingPathComponent("Amore-Picker-Note.txt"), options: .atomic)
            if let zip = Data(base64Encoded: fixture) {
                try zip.write(to: documents.appendingPathComponent("Amore-Picker-History.zip"), options: .atomic)
            }
        } catch {
            assertionFailure("Could not create simulator document fixtures.")
        }
    }

    // ZIP32 DEFLATE, one synthetic message and a v3 manifest, no account data.
    private static let fixture = "UEsDBBQAAAAIAMBkeF3qDWnsPgAAAGIAAAAXAAAAY2hhdF9zZXNzaW9uX2luZGV4Lmpzb26LrlbKTFGyUipOzC3ISVXSUcrMK04tKklNiU8sAQobGRiZ6Roa6hoahRgYWIGRnoGBQRRQYWlBSiJhdbWxAFBLAwQUAAAACADAZHhd4bli+7QAAAAHAQAAGQAAAGNoYXRfc2Vzc2lvbnMvc2FtcGxlLmpzb26Vjd0KwjAMhV9l5HqTbogXvRNWcSCibt5MRIrLpND90GagiO9uOp9AEgg5J/nOG0wDErzuRosQAxniKWFjnjS5oJjeoyNsbppYz0S2StI0SbNKCDn3QghR82GH3usHepCX90wVMYzaYU+3sPWTtTG4YcafS3XiF0+aJh/iin1RblX+T17r9KNj+i+QXmMAn9TxrMqK7fvQE7usbdHaIWrd0EV1cVgtk9YhRrna7NaVgs+V6wtQSwMEFAAAAAgAwGR4XR/IYiMdAAAAGwAAAA0AAABtYW5pZmVzdC5qc29uq1ZKrSjILyqJT8svyk0siS9LLSrOzM9TsjKuBQBQSwECFAMUAAAACADAZHhd6g1p7D4AAABiAAAAFwAAAAAAAAAAAAAAgAEAAAAAY2hhdF9zZXNzaW9uX2luZGV4Lmpzb25QSwECFAMUAAAACADAZHhd4bli+7QAAAAHAQAAGQAAAAAAAAAAAAAAgAFzAAAAY2hhdF9zZXNzaW9ucy9zYW1wbGUuanNvblBLAQIUAxQAAAAIAMBkeF0fyGIjHQAAABsAAAANAAAAAAAAAAAAAACAAV4BAABtYW5pZmVzdC5qc29uUEsFBgAAAAADAAMAxwAAAKYBAAAAAA=="
}
#endif
