#!/usr/bin/env python3

import argparse
import pathlib
import sys

from pylxd import Client


def fail(message):
    print(f"incus-runtime-health: {message}", file=sys.stderr)
    raise SystemExit(1)


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("--runtime", required=True)
    parser.add_argument("--lxcfs", required=True)
    return parser.parse_args()


def main():
    args = parse_args()
    endpoint = pathlib.Path(args.endpoint)
    runtime = pathlib.Path(args.runtime)
    meminfo = pathlib.Path(args.lxcfs) / "proc/meminfo"

    if not endpoint.is_socket():
        fail(f"Incus Unix socket is missing: {endpoint}")
    if not runtime.is_dir():
        fail(f"Incus runtime directory is missing: {runtime}")

    try:
        with meminfo.open("rb") as stream:
            if not stream.read(1):
                fail(f"LXCFS health file is empty: {meminfo}")
    except OSError as exc:
        fail(f"LXCFS data plane is unavailable at {meminfo}: {exc}")

    try:
        Client(endpoint=str(endpoint)).host_info
    except Exception as exc:
        fail(f"Incus API health check failed: {exc}")


if __name__ == "__main__":
    main()
