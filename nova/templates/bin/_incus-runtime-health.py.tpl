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
    parser.add_argument("--project", required=True)
    return parser.parse_args()


def validate_no_managed_networks(client):
    response = client.api.networks.get(params={
        "recursion": "1",
        "all-projects": "true",
    })
    managed = sorted(
        f"{network.get('project') or 'default'}/{network.get('name')}"
        for network in response.json().get("metadata", [])
        if network.get("managed")
    )
    if managed:
        fail(
            "Incus-managed networks are unsupported on Neutron nodes: "
            + ", ".join(managed))


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
        host_client = Client(endpoint=str(endpoint))
        host_client.host_info
        validate_no_managed_networks(host_client)
        client = Client(endpoint=str(endpoint), project=args.project)
        instances = client.instances.all()
    except Exception as exc:
        fail(f"Incus API health check failed: {exc}")

    for instance in instances:
        if instance.status.lower() != "running":
            continue

        runtime_name = instance.name
        if args.project != "default":
            runtime_name = f"{args.project}_{instance.name}"
        config = runtime / runtime_name / "lxc.conf"
        if not config.is_file():
            fail(
                f"runtime config for {args.project}/{instance.name} "
                f"is missing: {config}")


if __name__ == "__main__":
    main()
