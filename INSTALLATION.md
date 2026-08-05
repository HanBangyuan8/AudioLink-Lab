# Installation and build

Requirements: macOS 13 or newer, Xcode 16 or newer, Swift 6, and an Apple
Silicon or Intel Mac. The iOS companion requires an iOS 16 SDK and a signing
team for device installation.

## Development build

```bash
./Scripts/test-packages.sh
./Scripts/build-all.sh
./Scripts/package-app.sh development
open "dist/AudioLink Lab.app"
```

The app bundle is ad-hoc/unsigned for local development. It is not notarized
and may require the user to approve it in Privacy & Security. A distribution
build must be produced by a developer with a Developer ID certificate,
entitlements, provisioning profiles, archive/export settings, and notarization
credentials. The repository deliberately does not fake those credentials.

## Validation and benchmarks

The optional Python validation environment is separate from runtime:

```bash
python3 -m venv .venv-validation
. .venv-validation/bin/activate
python3 -m pip install -r Validation/requirements.txt
python3 Validation/run_validation.py --profile quick
./Scripts/run-benchmarks.sh quick
```

The current host may not have NumPy/SciPy installed; in that case validation is
reported as unverified rather than silently skipped.

On this host, the direct SwiftPM iPhoneOS/Simulator cross-build prints the
toolchain warning `using sysroot for 'MacOSX' but targeting 'iPhone'` while
linking. Swift source compilation with `-warnings-as-errors` succeeds; this is
an Xcode/SwiftPM cross-SDK diagnostic, not a project Swift warning. A production
Xcode project/archive should be used to eliminate or review that toolchain
warning before distribution.
