# Contributing to AudioLink Lab

Thank you for helping build AudioLink Lab. Keep changes small, testable, and
within the existing dependency boundaries.

## Development workflow

1. Create a focused branch and describe the measurement or engineering problem.
2. Put reusable models and protocols in `AudioLinkCore`, algorithms in
   `AudioLinkDSP`, persistence in `AudioLinkStorage`, and transport code in
   `AudioLinkNetworking`.
3. Keep SwiftUI views declarative. Business state and algorithms must remain
   outside views and global mutable singletons are not accepted.
4. Add deterministic tests. Audio hardware-dependent tests must be separated
   from unit tests and clearly labelled when they are introduced.
5. Run `./Scripts/test-packages.sh` and `./Scripts/build-all.sh` before opening a
   pull request.

Use explicit physical units in names and APIs. Avoid force unwraps, unexplained
unsafe operations, third-party dependencies without prior discussion, and
unrelated rewrites. Public model changes should preserve Codable compatibility
or document a migration plan.

Bug reports should include macOS version, hardware architecture, audio device
details, sample rate, channel configuration, and reproducible steps when known.

