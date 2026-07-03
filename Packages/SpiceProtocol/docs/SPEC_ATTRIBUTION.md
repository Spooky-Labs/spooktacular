# Spec Attribution

`SpiceProtocol` is a clean-room Swift reimplementation of the SPICE
`vd_agent` wire protocol. This document records the chain of custody
from the public specification to the Swift source in this package —
reviewers can walk any constant or layout here back to its primary
source without reading LGPL/GPL code.

## Primary sources

- [SPICE Protocol](https://www.spice-space.org/spice-protocol.html)
  — the umbrella protocol spec. Defines the link handshake,
  `SPICE_LINK_ERR_*` error codes, `SPICE_MSG_NOTIFY` severity
  levels, channel framing, and the `SPICE_MSG_MAIN_AGENT_DATA`
  wrapper inside which every agent-protocol message travels.
  Our `SpiceLinkError` / `SpiceNotifySeverity` / `SpiceNotifyWarning`
  / `SpiceNotifyInfo` enums are typed transcriptions of the
  `SPICE_LINK_ERR_*` / `SPICE_WARN_*` / `SPICE_INFO_*` /
  `SPICE_NOTIFY_SEVERITY_*` constant tables in this spec.
- [SPICE Agent Protocol](https://www.spice-space.org/agent-protocol.html)
  — the vd_agent sub-protocol. Clipboard message framing,
  capability negotiation rules, selection-prefix layout, and
  data-type constants all come from this document.

## Values verified against public headers

The numeric values assigned to enums in this package were
cross-referenced with the public `spice-protocol` project's C headers:

- [`spice/vd_agent.h`](https://gitlab.freedesktop.org/spice/spice-protocol/-/blob/master/spice/vd_agent.h)
  — BSD 3-Clause. We did not copy source, only read the `#define`
  numeric constants to sanity-check our Swift enum raw values.

## Implementation choices verified against an existing agent

Some implementation details (which capability bits a modern macOS
guest announces, whether selection-prefixed messages are sent, what
image types are supported) are stated in the spec only ambiguously.
We verified our choices against UTM's vd_agent fork via DeepWiki
queries about behaviour, not source:

- <https://github.com/utmapp/vd_agent> (GPL-2.0) — we read their
  README and ran DeepWiki Q&A against the repository to confirm
  things like "the macOS daemon does not set `VD_AGENT_CAP_MOUSE_STATE`"
  and "clipboard messages carry the 4-byte selection prefix when
  `VD_AGENT_CAP_CLIPBOARD_SELECTION` is negotiated." No source code
  was read or copied.

## What this package does NOT contain

- No code from `spice-vdagent` (GPL-3+).
- No code from `utmapp/vd_agent` (GPL-2.0).
- No code from `spice-gtk` (LGPL-2.1+).
- No code from `spice-server` (LGPL-2.1+).
- No bundled `spice-protocol` C headers (they're BSD, but we don't
  need the runtime dependency — our Swift enums mirror the same
  constants directly, and the sanity-check against those headers is
  a build-time concern, not a runtime one).

## Resulting license

Every line of Swift in `Sources/` was authored for this package.
Licensed under MIT (see LICENSE).
