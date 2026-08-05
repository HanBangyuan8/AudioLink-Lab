# Security policy

AudioLink Lab is a local measurement tool. The current LAN implementation uses
bounded TCP framing, explicit user pairing, a short-code confirmation, session
tokens, replay checks, path validation, and SHA-256 file checksums. It does not
provide TLS, authenticated peer identities, forward secrecy, or protection from
a hostile or compromised local network. Do not describe v1 as end-to-end
encrypted.

The default offline workflow does not open a listening network service. The
Bonjour/mobile workflow is opt-in and should only be used on a trusted LAN.
Unknown peers require an explicit user confirmation; a matching device name is
not proof of identity. File transfers are written to a random temporary file,
verified, and atomically moved; interrupted transfers are removed.

Please report security issues privately to the repository owner before opening a
public issue. Include the affected version, platform, reproducible steps, and a
minimal redacted log. Never attach a recording or security-scoped bookmark.

Until a signed release process and TLS identity pinning are available, the
recommended deployment is an unsigned development build on a trusted machine,
with networking disabled when it is not needed.
