#!/usr/bin/env python3

import json
import os
import pathlib
import sys
import time

from cryptography import x509
from cryptography.hazmat.primitives import hashes
from pylxd import Client
from pylxd import exceptions as pylxd_exceptions


def fail(message):
    print(f"incus-storage-init: {message}", file=sys.stderr)
    raise SystemExit(1)


def install_file(source, destination, mode):
    source_path = pathlib.Path(source)
    destination_path = pathlib.Path(destination)
    if not source_path.is_file():
        fail(f"required file is missing: {source_path}")

    content = source_path.read_bytes()
    destination_path.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    temporary_path = destination_path.with_name(
        f".{destination_path.name}.tmp-{os.getpid()}")
    temporary_path.write_bytes(content)
    os.chmod(temporary_path, mode)
    os.replace(temporary_path, destination_path)


def install_ceph_credentials():
    if os.environ.get("INCUS_CEPH_ENABLED", "false").lower() != "true":
        return

    cluster = os.environ.get("INCUS_CEPH_CLUSTER", "ceph")
    host_directory = pathlib.Path(
        os.environ.get("INCUS_HOST_CEPH_DIR", "/host/etc/ceph"))
    install_file(
        "/run/incus-storage/ceph.conf",
        host_directory / f"{cluster}.conf",
        0o644,
    )

    try:
        keyrings = json.loads(os.environ.get("INCUS_CEPH_KEYRINGS", "{}"))
    except json.JSONDecodeError as exc:
        fail(f"INCUS_CEPH_KEYRINGS is not valid JSON: {exc}")
    if not keyrings:
        fail("at least one Ceph keyring must be configured")

    for key_id, definition in keyrings.items():
        user = definition.get("user") if isinstance(definition, dict) else None
        if not user:
            fail(f"Ceph keyring {key_id!r} has no user")
        key = pathlib.Path(
            f"/run/incus-storage/ceph-keys/{key_id}").read_text().strip()
        if not key:
            fail(f"Ceph keyring {key_id!r} is empty")

        keyring = host_directory / f"{cluster}.client.{user}.keyring"
        temporary_keyring = pathlib.Path(f"{keyring}.tmp-{os.getpid()}")
        temporary_keyring.write_text(f"[client.{user}]\n\tkey = {key}\n")
        os.chmod(temporary_keyring, 0o600)
        os.replace(temporary_keyring, keyring)
        print(f"incus-storage-init: installed Ceph keyring for client.{user}")


def connect_client():
    endpoint = os.environ.get("INCUS_ENDPOINT", "/var/lib/incus/unix.socket")
    deadline = time.monotonic() + int(
        os.environ.get("INCUS_STORAGE_INIT_TIMEOUT", "120"))
    last_error = None

    while time.monotonic() < deadline:
        try:
            client = Client(endpoint=endpoint)
            client.host_info
            return client
        except Exception as exc:
            last_error = exc
            time.sleep(2)

    fail(f"Incus API did not become ready at {endpoint}: {last_error}")


def desired_pools():
    try:
        pools = json.loads(os.environ.get("INCUS_STORAGE_POOLS", "{}"))
    except json.JSONDecodeError as exc:
        fail(f"INCUS_STORAGE_POOLS is not valid JSON: {exc}")

    if not isinstance(pools, dict):
        fail("INCUS_STORAGE_POOLS must be a JSON object keyed by pool name")

    return {name: spec for name, spec in pools.items() if spec is not None}


def ceph_users():
    if os.environ.get("INCUS_CEPH_ENABLED", "false").lower() != "true":
        return set()

    try:
        keyrings = json.loads(os.environ.get("INCUS_CEPH_KEYRINGS", "{}"))
    except json.JSONDecodeError as exc:
        fail(f"INCUS_CEPH_KEYRINGS is not valid JSON: {exc}")

    return {
        definition.get("user")
        for definition in keyrings.values()
        if isinstance(definition, dict) and definition.get("user")
    }


def pool_config(spec):
    config = spec.get("config", {})
    if not isinstance(config, dict):
        fail("storage pool config must be an object")
    config = {str(key): str(value) for key, value in config.items()}

    source = spec.get("source")
    if source is not None:
        source = str(source)
        if "source" in config and config["source"] != source:
            fail("storage pool source conflicts with config.source")
        config["source"] = source

    return config


def reconcile_pool(client, name, spec, installed_ceph_users):
    if not isinstance(spec, dict):
        fail(f"storage pool {name!r} definition must be an object or null")

    driver = spec.get("driver")
    if not driver:
        fail(f"storage pool {name!r} has no driver")
    config = pool_config(spec)
    if driver in {"ceph", "cephext"}:
        keyring_id = spec.get("ceph_keyring") or os.environ.get(
            "INCUS_CEPH_DEFAULT_KEYRING")
        try:
            keyrings = json.loads(os.environ.get("INCUS_CEPH_KEYRINGS", "{}"))
        except json.JSONDecodeError as exc:
            fail(f"INCUS_CEPH_KEYRINGS is not valid JSON: {exc}")
        keyring = keyrings.get(keyring_id, {})
        if not keyring.get("user"):
            fail(
                f"storage pool {name!r} references unknown Ceph keyring "
                f"{keyring_id!r}")
        config.setdefault("ceph.cluster_name", os.environ.get(
            "INCUS_CEPH_CLUSTER", "ceph"))
        config.setdefault("ceph.user.name", keyring["user"])
        source = config.get("source")
        user = config.get("ceph.user.name")
        if not source:
            fail(f"storage pool {name!r} requires config.source")
        if not user:
            fail(f"storage pool {name!r} requires config.ceph.user.name")
        if user not in installed_ceph_users:
            fail(
                f"storage pool {name!r} references Ceph user {user!r}, "
                "but no matching incus_storage.ceph.keyrings entry exists")

    try:
        pool = client.storage_pools.get(name)
        created = False
    except pylxd_exceptions.NotFound:
        print(f"incus-storage-init: creating pool {name!r} with driver {driver!r}")
        client.storage_pools.create({
            "name": name,
            "driver": driver,
            "description": spec.get("description", "Managed by OpenStack-Helm"),
            "config": config,
        })
        pool = client.storage_pools.get(name)
        created = True

    if pool.driver != driver:
        fail(
            f"storage pool {name!r} uses driver {pool.driver!r}, "
            f"expected {driver!r}")

    actual_config = pool.config or {}
    mismatches = {
        key: {"actual": actual_config.get(key), "expected": value}
        for key, value in config.items()
        if actual_config.get(key) != value
    }
    if mismatches:
        fail(f"storage pool {name!r} config mismatch: {mismatches}")

    action = "created" if created else "verified"
    print(f"incus-storage-init: {action} pool {name!r} ({driver})")
    return pool


def validate_nova_pool(client, name, purpose, required_driver=None):
    if not name:
        if purpose == "root":
            fail("[incus] storage_pool must be configured")
        return

    try:
        pool = client.storage_pools.get(name)
    except pylxd_exceptions.NotFound:
        fail(f"Nova {purpose} storage pool {name!r} does not exist")

    if required_driver and pool.driver != required_driver:
        fail(
            f"Nova {purpose} storage pool {name!r} must use "
            f"{required_driver!r}, found {pool.driver!r}")


def reconcile_preflight_project(client):
    try:
        bfv_pools = json.loads(os.environ.get("INCUS_BFV_STORAGE_POOLS", "{}"))
    except json.JSONDecodeError as exc:
        fail(f"INCUS_BFV_STORAGE_POOLS is not valid JSON: {exc}")
    if not bfv_pools:
        return
    if not isinstance(bfv_pools, dict) or not all(
            isinstance(source, str) and isinstance(pool, str)
            for source, pool in bfv_pools.items()):
        fail("INCUS_BFV_STORAGE_POOLS must be a string mapping")

    name = os.environ.get("INCUS_PREFLIGHT_PROJECT", "nova-preflight")
    desired = {
        "features.images": "false",
        "features.profiles": "true",
        "restricted": "true",
        "limits.containers": "0",
        "limits.virtual-machines": "0",
        "user.openstack.preflight_protocol": "1",
        "user.openstack.bfv_storage_pools": json.dumps(
            bfv_pools, sort_keys=True, separators=(",", ":")),
    }
    try:
        project = client.projects.get(name)
    except pylxd_exceptions.NotFound:
        client.projects.create(
            name,
            description="Nova Incus migration readiness only",
            config=desired,
        )
        print(f"incus-storage-init: created preflight project {name!r}")
        return

    config = dict(project.config or {})
    mismatches = {
        key: {"actual": config.get(key), "expected": value}
        for key, value in desired.items()
        if config.get(key) != value
    }
    if mismatches:
        config.update(desired)
        project.config = config
        project.save(wait=True)
        print(
            f"incus-storage-init: reconciled preflight project {name!r}: "
            f"{mismatches}")
    else:
        print(f"incus-storage-init: verified preflight project {name!r}")


def certificate_fingerprint(path):
    certificate = x509.load_pem_x509_certificate(pathlib.Path(path).read_bytes())
    return certificate.fingerprint(hashes.SHA256()).hex()


def reconcile_trust_certificate(client, path, name, projects):
    fingerprint = certificate_fingerprint(path)
    try:
        certificate = client.certificates.get(fingerprint)
    except pylxd_exceptions.NotFound:
        client.certificates.create(
            "",
            pathlib.Path(path).read_bytes(),
            name=name,
            projects=projects,
            restricted=True,
        )
        print(f"incus-storage-init: trusted restricted identity {name!r}")
        return fingerprint

    changed = False
    if certificate.name != name:
        certificate.name = name
        changed = True
    if set(certificate.projects or []) != set(projects):
        certificate.projects = projects
        changed = True
    if not certificate.restricted:
        certificate.restricted = True
        changed = True
    if changed:
        certificate.save(wait=True)
        print(f"incus-storage-init: reconciled restricted identity {name!r}")
    else:
        print(f"incus-storage-init: verified restricted identity {name!r}")
    return fingerprint


def reconcile_migration_trust(client):
    if os.environ.get("INCUS_MIGRATION_ENABLED", "false").lower() != "true":
        return

    nova_project = os.environ.get("NOVA_INCUS_PROJECT", "default")
    migration_fingerprint = reconcile_trust_certificate(
        client,
        "/run/incus-migration/migration.crt",
        "nova-incus-migration",
        [nova_project],
    )
    bfv_pools = json.loads(os.environ.get("INCUS_BFV_STORAGE_POOLS", "{}"))
    if bfv_pools:
        preflight_project = os.environ.get(
            "INCUS_PREFLIGHT_PROJECT", "nova-preflight")
        preflight_fingerprint = reconcile_trust_certificate(
            client,
            "/run/incus-migration/preflight.crt",
            "nova-incus-preflight",
            [preflight_project],
        )
        if migration_fingerprint == preflight_fingerprint:
            fail(
                "migration and preflight identities must use different "
                "certificates")


def main():
    install_ceph_credentials()
    client = connect_client()
    for name, spec in desired_pools().items():
        reconcile_pool(client, name, spec, ceph_users())

    validate_nova_pool(client, os.environ.get("NOVA_INCUS_STORAGE_POOL"), "root")
    reconcile_preflight_project(client)
    reconcile_migration_trust(client)


if __name__ == "__main__":
    main()
