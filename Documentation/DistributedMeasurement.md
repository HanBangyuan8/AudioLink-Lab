# Distributed Measurement Network

`AudioLinkDistributed` adds a coordinator-owned star topology for simulated
and future multi-node sessions. Nodes advertise capabilities, receive explicit
assignments, and advance through invited → ready → armed → running → uploading
→ analyzing → completed. The coordinator refuses to arm until every required
node is ready and rejects messages carrying another session ID.

Clock synchronization uses the existing four-timestamp ping-pong observation.
RTT, offset, drift, observation age, scheduling, callback, and network
asymmetry are retained separately. `UncertaintyBudget` combines declared
components by root-sum-square; the final acoustic arrival is never replaced by
a network timestamp. Failure policy is explicit (fail all, continue, retry,
skip, or wait for reconnect), and missing nodes are listed in results.

This release does not claim a hard real-device node-count limit, sub-sample
cross-device synchronization, arbitrary mesh routing, or automatic spatial
acoustic alignment. Bonjour/Network security limits remain those in
`PROTOCOL.md`; real multi-device validation is a manual checklist item.
