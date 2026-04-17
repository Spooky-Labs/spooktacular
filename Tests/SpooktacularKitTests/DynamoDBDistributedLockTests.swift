import Testing
import Foundation
@testable import SpookCore
@testable import SpookApplication
@testable import SpookInfrastructureApple

/// Tests for the credential-shape validators on
/// ``DynamoDBDistributedLock``. Network-backed round-trips live
/// in `EnterpriseIntegrationTests` behind credential gating; the
/// init-time rejection is pure and testable here.
@Suite("DynamoDB distributed lock", .tags(.security, .infrastructure))
struct DynamoDBDistributedLockTests {

    @Test("IAM long-term access key ID is accepted")
    func validAkiaKey() throws {
        try DynamoDBDistributedLock.validateAccessKeyID("AKIAIOSFODNN7EXAMPLE")
    }

    @Test("STS short-term access key ID is accepted")
    func validAsiaKey() throws {
        try DynamoDBDistributedLock.validateAccessKeyID("ASIAIOSFODNN7EXAMPLE")
    }

    @Test("Access key ID wrong length is rejected")
    func keyWrongLength() {
        #expect(throws: DynamoDBLockError.invalidAccessKeyID) {
            try DynamoDBDistributedLock.validateAccessKeyID("AKIA")
        }
        #expect(throws: DynamoDBLockError.invalidAccessKeyID) {
            try DynamoDBDistributedLock.validateAccessKeyID("AKIAIOSFODNN7EXAMPLE123")
        }
    }

    @Test("Access key ID wrong prefix is rejected")
    func keyWrongPrefix() {
        #expect(throws: DynamoDBLockError.invalidAccessKeyID) {
            try DynamoDBDistributedLock.validateAccessKeyID("XXXXIOSFODNN7EXAMPLE")
        }
    }

    @Test("Access key ID with lowercase is rejected")
    func keyWithLowercase() {
        #expect(throws: DynamoDBLockError.invalidAccessKeyID) {
            try DynamoDBDistributedLock.validateAccessKeyID("akiaiosfodnn7example")
        }
    }

    @Test("Access key ID with special char is rejected")
    func keyWithSpecial() {
        #expect(throws: DynamoDBLockError.invalidAccessKeyID) {
            try DynamoDBDistributedLock.validateAccessKeyID("AKIAIOSFODNN7EXAMPL!")
        }
    }

    @Test("Secret access key within length + charset is accepted")
    func validSecretKey() throws {
        try DynamoDBDistributedLock.validateSecretAccessKey(
            "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
        )
        // Boundary lengths.
        try DynamoDBDistributedLock.validateSecretAccessKey(String(repeating: "a", count: 16))
        try DynamoDBDistributedLock.validateSecretAccessKey(String(repeating: "a", count: 128))
    }

    @Test("Secret access key too short is rejected")
    func secretTooShort() {
        #expect(throws: DynamoDBLockError.invalidSecretAccessKey) {
            try DynamoDBDistributedLock.validateSecretAccessKey("short")
        }
    }

    @Test("Secret access key too long is rejected")
    func secretTooLong() {
        #expect(throws: DynamoDBLockError.invalidSecretAccessKey) {
            try DynamoDBDistributedLock.validateSecretAccessKey(String(repeating: "a", count: 129))
        }
    }

    @Test("Secret access key with non-printable byte is rejected")
    func secretNonPrintable() {
        #expect(throws: DynamoDBLockError.invalidSecretAccessKey) {
            try DynamoDBDistributedLock.validateSecretAccessKey("abc\u{0001}defghijklmno")
        }
    }
}
