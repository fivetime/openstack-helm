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
    return parser.parse_args()


def main():
    args = parse_args()
    endpoint = pathlib.Path(args.endpoint)
    runtime = pathlib.Path(args.runtime)

    if not endpoint.is_socket():
        fail(f"Incus Unix socket is missing: {endpoint}")
    if not runtime.is_dir():
        fail(f"Incus runtime directory is missing: {runtime}")

    # LXCFS is not checked here. This container does not use it, and its
    # bind mount keeps the FUSE connection it was started with: after a host
    # LXCFS restart it reads a dead mount while the host serves a live one,
    # and readiness would fail for as long as the pod lives. incusd checks
    # the host LXCFS itself, and the Incus exporter of the masakari chart
    # alerts on it. The storage init container still checks it at start.

    try:
        Client(endpoint=str(endpoint)).host_info
    except Exception as exc:
        fail(f"Incus API health check failed: {exc}")


if __name__ == "__main__":
    main()
