import Testing
@testable import SpooktacularInfrastructureApple

@Suite("SHA512Crypt")
struct SHA512CryptTests {

    @Test("Drepper reference vector: simple salt")
    func referenceVector1() throws {
        #expect(try SHA512Crypt.hash(password: "Hello world!", salt: "saltstring")
            == "$6$saltstring$svn8UoSVapNtMuq1ukKS4tPQd8iKwSMHWjl/O817G3uBnIFNjnQJuesI68u4OTLiBFdcbYEdFCoEOfaS35inz1")
    }

    @Test("salt longer than 16 chars is truncated to 16 (spec rule)")
    func saltTruncation() throws {
        let full = try SHA512Crypt.hash(password: "Hello world!", salt: "saltstringsaltstring")
        let sixteen = try SHA512Crypt.hash(password: "Hello world!", salt: "saltstringsaltst")
        #expect(full == sixteen)
    }

    @Test("generated salt is 16 chars from the crypt alphabet")
    func saltAlphabet() {
        let salt = SHA512Crypt.generateSalt()
        #expect(salt.count == 16)
        let allowed = Set("./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        #expect(salt.allSatisfy { allowed.contains($0) })
    }

    @Test("dollar sign in salt is rejected")
    func rejectsIllegalSalt() {
        #expect(throws: SHA512CryptError.invalidSalt) {
            _ = try SHA512Crypt.hash(password: "x", salt: "bad$salt")
        }
    }
}
