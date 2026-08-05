# Audio Unit Plugin Profiler

`AudioLinkPlugin` defines a helper-process boundary (`AudioUnitHelperRequest`/`Response`), a timeout, sanitisation of NaN/infinite output, and typed reported-versus-measured results. Deterministic mock runners cover pass-through, fixed delay, gain, polarity inversion, low-pass, distortion, noise, tail, NaN, crash and hang behaviours.

The first production slice intentionally does not load arbitrary third-party components in the app process. A real AUv2/AUv3 scan/render helper and signed XPC entitlement setup remain deployment work. Validation status is never inferred from a mock result, and VST3 is not claimed. Repeatedly crashing or timing-out plugins stay in safe mode until the user explicitly retries them.
