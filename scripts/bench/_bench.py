#!/usr/bin/env python3
"""Drives the booted scripted-lane serve, times it, and writes the artifact.

Stdlib only. Fails (exit 1) when the lane is not scripted, a request errors, the
streamed bytes drift from the script, or usage diverges from the declared counts —
a benchmark whose work may not have run prints no numbers. Timing is client-side
wall clock around the request; the server's own /v1/stats body rides along verbatim
for cross-checking.
"""
import argparse
import hashlib
import json
import os
import platform
import shutil
import statistics
import subprocess
import sys
import time
import urllib.request

PROMPT = ("Benchmark prompt. " * 40).strip()


def post(port, path, body, stream=False):
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    t0 = time.perf_counter()
    resp = urllib.request.urlopen(req, timeout=120)
    if resp.status != 200:
        sys.exit(f"FAIL {path} returned {resp.status}")
    return resp, t0


def timed_stream(port):
    """One streaming turn: (total_s, ttft_s, joined_content, usage)."""
    resp, t0 = post(
        port,
        "/v1/chat/completions",
        {"model": "scripted-model", "messages": [{"role": "user", "content": PROMPT}],
         "stream": True},
        stream=True,
    )
    first = None
    parts = []
    usage = None
    for raw in resp:
        line = raw.decode().strip()
        if not line.startswith("data:"):
            continue
        if first is None:
            first = time.perf_counter()
        payload = line[5:].strip()
        if payload == "[DONE]":
            break
        chunk = json.loads(payload)
        if chunk.get("usage"):
            usage = chunk["usage"]
        for choice in chunk.get("choices", []):
            piece = (choice.get("delta") or {}).get("content")
            if piece:
                parts.append(piece)
    total = time.perf_counter() - t0
    return total, first - t0, "".join(parts), usage


def timed_completion(port):
    t0 = time.perf_counter()
    resp = urllib.request.urlopen(
        urllib.request.Request(
            f"http://127.0.0.1:{port}/v1/chat/completions",
            data=json.dumps({"model": "scripted-model",
                             "messages": [{"role": "user", "content": PROMPT}]}).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        ),
        timeout=120,
    )
    body = json.loads(resp.read())
    elapsed = time.perf_counter() - t0
    if not body.get("choices") or body["choices"][0].get("finish_reason") is None:
        sys.exit("FAIL non-streaming turn has no finish_reason — work may not have run")
    return elapsed, body


def git(root, *args):
    return subprocess.run(["git", *args], cwd=root, capture_output=True, text=True).stdout.strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--repeats", type=int, default=3)
    ap.add_argument("--out", required=True)
    ap.add_argument("--repo-root", required=True)
    ap.add_argument("--expect-script", required=True)
    ap.add_argument("--bin", required=True)
    a = ap.parse_args()

    script = json.load(open(a.expect_script))
    # The scripted lane trims edge whitespace off the assembled content channel
    # (measured: a space-prefixed first segment lost its space, the final trailing
    # space is dropped, interior bytes are byte-exact). Interior equality is the
    # real work-happened check; the edge rule is this lane's contract as measured,
    # not an assumption.
    expect_text = "".join(script["segments"]).strip()

    with urllib.request.urlopen(f"http://127.0.0.1:{a.port}/v1/capabilities", timeout=30) as r:
        caps = json.load(r)
    if caps.get("engineBackend") != "scripted":
        sys.exit(f"FAIL engineBackend={caps.get('engineBackend')!r} — timed region is not the scripted lane")

    tok_s, ttft_ms, latency_ms = [], [], []
    usage = None
    for _ in range(a.repeats):
        total, first, text, _ = timed_stream(a.port)
        if text != expect_text:
            sys.exit("FAIL streamed content drifted from the script — timed the wrong work")
        tok_s.append(script["generatedTokens"] / total)
        ttft_ms.append(first * 1000)
    for _ in range(a.repeats):
        elapsed, body = timed_completion(a.port)
        latency_ms.append(elapsed * 1000)
        if usage is None:
            # The non-streaming usage object is the contract carrier (probe 37 §5);
            # the scripted stream lane ends at the finish frame and publishes none.
            usage = body.get("usage") or {}
            if (usage.get("prompt_tokens") != script["promptTokens"]
                    or usage.get("completion_tokens") != script["generatedTokens"]):
                sys.exit(f"FAIL usage {usage} diverges from declared "
                         f"{script['promptTokens']}/{script['generatedTokens']}")

    with urllib.request.urlopen(f"http://127.0.0.1:{a.port}/v1/stats", timeout=30) as r:
        server_stats = json.load(r)

    mac = platform.mac_ver()[0]
    binary = {"path": a.bin, "size_bytes": os.path.getsize(a.bin)}

    def summarize(samples):
        return {"median": round(statistics.median(samples), 3),
                "samples": [round(s, 3) for s in samples]}

    artifact = {
        "schema": 1,
        "lane": "scripted",
        "publish_status": "internal preparation — external publication needs release authorization",
        "regenerate": "make bench",
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "tree": {"commit": git(a.repo_root, "rev-parse", "HEAD"),
                 "dirty_paths": len(git(a.repo_root, "status", "--porcelain").splitlines())},
        "host": {"chip": subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"],
                                        capture_output=True, text=True).stdout.strip(),
                 "arch": platform.machine(), "macos": mac, "kernel": platform.release(),
                 "python": platform.python_version()},
        "toolchain": shutil.which("swift"),
        "binary": binary,
        "conditions": {
            "repeats": a.repeats,
            "script": {"segments": len(script["segments"]),
                       "prompt_tokens": script["promptTokens"],
                       "generated_tokens": script["generatedTokens"]},
            "prompt_sha256": hashlib.sha256(PROMPT.encode()).hexdigest()[:16],
            "prompt_bytes": len(PROMPT.encode()),
            "request_params": {
                "temperature": "omitted — server default applies; the scripted lane emits "
                               "declared tokens, so sampling is not exercised on this lane",
                "seed": "n/a — no sampling on this lane",
            },
            "limiter_note": "scripted lane emits pre-declared tokens: tok_s is HTTP/SSE "
                            "plumbing overhead, not model throughput",
        },
        "metrics": {
            "tok_s": summarize(tok_s),
            "ttft_ms": summarize(ttft_ms),
            "req_latency_ms": summarize(latency_ms),
            "prompt_tokens_server": usage.get("prompt_tokens"),
        },
        "server_stats_raw": server_stats,
        "correctness": {"stream_bytes_match": True, "usage_equals_declared": True},
    }
    with open(a.out, "w") as f:
        json.dump(artifact, f, indent=2)
        f.write("\n")
    m = artifact["metrics"]
    print(f"OK artifact {a.out}")
    print(f"   tok_s median {m['tok_s']['median']} (overhead lane) | ttft_ms median "
          f"{m['ttft_ms']['median']} | req_latency_ms median {m['req_latency_ms']['median']} | "
          f"prompt_tokens {m['prompt_tokens_server']}")


if __name__ == "__main__":
    main()
