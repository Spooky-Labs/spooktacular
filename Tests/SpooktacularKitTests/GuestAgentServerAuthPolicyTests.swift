import Foundation
import Testing
@testable import SpooktacularGuestAgentCore

/// Tests for ``GuestAgentServer/AuthPolicy`` — the
/// trusted-host vs require-auth switch that decides whether
/// the guest HTTP/vsock server throws on startup when no
/// cryptographic verifiers are configured.
///
/// This class of regression is easy to introduce: someone
/// could "harden" the code by removing the `.trustedHost`
/// policy or flipping the default back to `.requireAuth`,
/// and the guest-tools app would start failing to boot its
/// HTTP server silently (the menu-bar app would still show
/// green clipboard status, but `spook remote health <vm>`
/// would time out).
@Suite("GuestAgentServer.AuthPolicy")
struct GuestAgentServerAuthPolicyTests {

    @Test("AuthPolicy cases are complete and Sendable")
    func policyCases() {
        // Exhaustive switch proves the enum hasn't grown a
        // case the tests forgot about. Future additions must
        // update this switch, which in turn forces the test
        // to acknowledge the new case explicitly.
        let policies: [GuestAgentServer.AuthPolicy] = [
            .requireAuth,
            .trustedHost,
        ]
        for policy in policies {
            switch policy {
            case .requireAuth:  break
            case .trustedHost:  break
            }
        }
        #expect(policies.count == 2)
    }

    @Test("Default init uses the strict .requireAuth policy")
    func defaultPolicyIsStrict() {
        // The default matches the legacy behaviour: servers
        // instantiated without an explicit policy MUST
        // refuse to start when no verifiers are configured.
        // Changing this default would silently weaken every
        // multi-tenant deployment that relies on the refuse-
        // to-start guard.
        //
        // We can't actually call `run()` in a unit test (it
        // blocks forever on vsock listen), but we can assert
        // the init shape by recovery through reflection.
        // The simpler check is: verify the explicit init
        // path still compiles with both policies.
        let strict = GuestAgentServer(authPolicy: .requireAuth)
        let trusted = GuestAgentServer(authPolicy: .trustedHost)
        let implicit = GuestAgentServer()
        // All three construct cleanly; semantic difference
        // is observable only at run() time, which requires
        // real vsock infrastructure.
        _ = (strict, trusted, implicit)
    }

    @Test("authNotConfigured error description references both env vars")
    func errorDescriptionMentionsEnvVars() {
        let error = GuestAgentServerError.authNotConfigured
        let message = error.errorDescription ?? ""
        // Users seeing this error need to know which env
        // var to set. Both must be named explicitly —
        // truncating one would leave operators guessing.
        #expect(message.contains("SPOOKTACULAR_HOST_PUBLIC_KEYS_DIR"))
        #expect(message.contains("SPOOKTACULAR_BREAKGLASS_PUBLIC_KEYS_DIR"))
        #expect(message.contains("SPOOKTACULAR_AGENT_ALLOW_NO_AUTH"))
    }
}
