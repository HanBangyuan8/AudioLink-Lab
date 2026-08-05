#!/usr/bin/env python3
"""Small stdlib-only client for the optional localhost automation service."""
import json
import sys
import time
import urllib.request


def request(url, token, method="GET", payload=None):
    data = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=10) as response:
        return json.load(response)


def main():
    if len(sys.argv) != 5:
        raise SystemExit("usage: audiolink_client.py URL TOKEN REFERENCE RECORDING")
    base, token, reference, recording = sys.argv[1:]
    job = request(base + "/v1/jobs/file-analysis", token, "POST", {
        "operation": "file-analysis",
        "referenceFile": reference,
        "recordingFile": recording,
        "configuration": {"channel": 0, "method": "automatic", "normalize": True},
    })
    job_id = job["jobID"]
    while True:
        status = request(base + f"/v1/jobs/{job_id}/status", token)
        print(json.dumps(status, indent=2, sort_keys=True))
        if status.get("state") in {"completed", "failed", "cancelled"}:
            break
        time.sleep(0.25)
    if status.get("state") == "completed":
        result = request(base + f"/v1/jobs/{job_id}/result", token)
        print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
