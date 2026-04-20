// SpooktacularKit — Umbrella module
//
// Re-exports SpooktacularCore, SpooktacularApplication, and SpooktacularInfrastructureApple
// so existing consumers (spook, Spooktacular, spook-controller) can
// continue to `import SpooktacularKit` without changes.
//
// New code should import the specific target it needs:
//   import SpooktacularCore             — domain types and protocols
//   import SpooktacularApplication      — use cases
//   import SpooktacularInfrastructureApple — Apple framework adapters

@_exported import SpooktacularCore
@_exported import SpooktacularApplication
@_exported import SpooktacularInfrastructureApple
