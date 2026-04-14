// SpooktacularKit — Umbrella module
//
// Re-exports SpookCore, SpookApplication, and SpookInfrastructureApple
// so existing consumers (spook, Spooktacular, spook-controller) can
// continue to `import SpooktacularKit` without changes.
//
// New code should import the specific target it needs:
//   import SpookCore             — domain types and protocols
//   import SpookApplication      — use cases
//   import SpookInfrastructureApple — Apple framework adapters

@_exported import SpookCore
@_exported import SpookApplication
@_exported import SpookInfrastructureApple
