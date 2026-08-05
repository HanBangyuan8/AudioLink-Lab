# Local automation security

The local automation service is optional and is not started by the app, CLI, or
login session. When explicitly started it binds a TCP listener to the IPv4
loopback endpoint (`127.0.0.1`) and enables `acceptLocalOnly`; it does not
advertise Bonjour or listen on a LAN interface.

Every request requires a per-process random bearer token. The token is not
written to reports, history, logs, or example files. Requests are size-limited,
jobs are concurrency-limited, and the service exposes only health, job status,
result, and cancellation routes.

File analysis accepts paths only under directories explicitly supplied when the
service is created. Paths are standardized and resolved through symlinks before
the allowed-root prefix check; `..`, absolute paths outside the root, and
symlink escapes are rejected. The service never provides an arbitrary file-read
or directory-listing endpoint.

The service keeps a bounded in-memory history (100 terminal jobs) and does not
persist input paths or recordings by default. Active jobs are still retained
until they reach a terminal state. Callers should use an application-container
directory or a security-scoped selection they already own. Localhost access is
not a substitute for OS user authentication: another process running as the
same user may be able to inspect the token or connect to the service. TLS and
remote authentication are intentionally not claimed.
