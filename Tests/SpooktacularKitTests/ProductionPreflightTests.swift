import Testing
import Foundation
@testable import SpookCore
@testable import SpookApplication

/// Covers the fail-fast startup gate that refuses to launch a
/// multi-tenant `spook serve` when the enterprise-review controls
/// (authorization, audit sink, non-insecure) aren't all present.
@Suite("Production preflight", .tags(.security))
struct ProductionPreflightTests {

    @Test("single-tenant deployments pass regardless of other knobs")
    func singleTenantPasses() throws {
        let p = ProductionPreflight(
            tenancyMode: .singleTenant,
            insecure: true,
            hasAuthorizationService: false,
            hasAuditSink: false
        )
        try p.validate()
    }

    @Test("multi-tenant + --insecure is rejected first")
    func multiTenantInsecureRejected() {
        let p = ProductionPreflight(
            tenancyMode: .multiTenant,
            insecure: true,
            hasAuthorizationService: true,
            hasAuditSink: true
        )
        #expect(throws: ProductionPreflightError.insecureModeInMultiTenant) {
            try p.validate()
        }
    }

    @Test("multi-tenant with no authorization service is rejected")
    func multiTenantRequiresAuthorization() {
        let p = ProductionPreflight(
            tenancyMode: .multiTenant,
            insecure: false,
            hasAuthorizationService: false,
            hasAuditSink: true
        )
        #expect(throws: ProductionPreflightError.multiTenantRequiresAuthorization) {
            try p.validate()
        }
    }

    @Test("multi-tenant with no audit sink is rejected")
    func multiTenantRequiresAudit() {
        let p = ProductionPreflight(
            tenancyMode: .multiTenant,
            insecure: false,
            hasAuthorizationService: true,
            hasAuditSink: false
        )
        #expect(throws: ProductionPreflightError.multiTenantRequiresAudit) {
            try p.validate()
        }
    }

    @Test("fully configured multi-tenant passes")
    func multiTenantFullyConfiguredPasses() throws {
        let p = ProductionPreflight(
            tenancyMode: .multiTenant,
            insecure: false,
            hasAuthorizationService: true,
            hasAuditSink: true
        )
        try p.validate()
    }

    @Test("every error case carries both a description and a recovery hint")
    func errorsHaveDescriptionAndRecovery() {
        let cases: [ProductionPreflightError] = [
            .insecureModeInMultiTenant,
            .multiTenantRequiresAuthorization,
            .multiTenantRequiresAudit,
        ]
        for err in cases {
            #expect(err.errorDescription?.isEmpty == false,
                    "\(err) should carry a human-readable description")
            #expect(err.recoverySuggestion?.isEmpty == false,
                    "\(err) should carry an actionable recovery hint")
        }
    }
}
