#!/usr/bin/env python3
"""
sign_sbom.py — Cryptographic signing and verification for CycloneDX BOMs.

Three signing modes (in order of preference):

  1. sigstore (keyless, OIDC-based) — requires `sigstore` Python package and a
     valid OIDC token (GitHub Actions, Google, Microsoft identity).
     Produces <name>.cyclonedx.json.sigstore  (bundle with transparency log entry).

  2. RSA / EC key-based (offline) — requires the `cryptography` Python package.
     Produces <name>.cyclonedx.json.sig  (base64-encoded signature).
     Key pair management: use --generate-key to create an EC P-256 key pair.

  3. Hash manifest (no external deps) — always available as a fallback.
     Writes boms/sbom-sha256-manifest.json  with SHA-256 of every BOM file.
     Not a signature but provides integrity anchoring for audit trails.

Usage:
  # Generate a signing key pair
  python3 scripts/sbom-lineage/sign_sbom.py --generate-key --key-prefix sbom-signing

  # Sign all BOMs with a key file
  python3 scripts/sbom-lineage/sign_sbom.py --mode key --private-key sbom-signing.pem

  # Verify signatures
  python3 scripts/sbom-lineage/sign_sbom.py --verify --public-key sbom-signing.pub.pem

  # Always-available hash manifest
  python3 scripts/sbom-lineage/sign_sbom.py --mode hash

  # Sigstore keyless (GitHub Actions / CI)
  python3 scripts/sbom-lineage/sign_sbom.py --mode sigstore
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

BOMS_DIR_DEFAULT = Path(__file__).parent / "boms"


# ── Backend availability ───────────────────────────────────────────────────────

def _try_import_cryptography():
    try:
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import ec
        from cryptography.hazmat.primitives.asymmetric.utils import (
            decode_dss_signature, encode_dss_signature,
        )
        return True, (hashes, serialization, ec, decode_dss_signature, encode_dss_signature)
    except ImportError:
        return False, None


def _try_import_sigstore():
    try:
        import sigstore  # type: ignore  # noqa: F401
        return True
    except ImportError:
        return False


# ── Hash manifest (no dependencies) ──────────────────────────────────────────

def write_hash_manifest(boms_dir: Path) -> Path:
    manifest: dict = {
        "generated":  datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "algorithm":  "sha256",
        "files":      {},
    }
    for bf in sorted(boms_dir.glob("*.cyclonedx.json")):
        digest = hashlib.sha256(bf.read_bytes()).hexdigest()
        manifest["files"][bf.name] = digest
    out = boms_dir / "sbom-sha256-manifest.json"
    out.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    return out


def verify_hash_manifest(boms_dir: Path) -> tuple[int, int]:
    manifest_path = boms_dir / "sbom-sha256-manifest.json"
    if not manifest_path.exists():
        print(f"No manifest found at {manifest_path}", file=sys.stderr)
        sys.exit(1)
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    ok = fail = 0
    for fname, expected in manifest["files"].items():
        fpath = boms_dir / fname
        if not fpath.exists():
            print(f"  ✗  MISSING  {fname}")
            fail += 1
            continue
        actual = hashlib.sha256(fpath.read_bytes()).hexdigest()
        if actual == expected:
            print(f"  ✓  OK       {fname}")
            ok += 1
        else:
            print(f"  ✗  TAMPERED {fname}")
            print(f"      expected: {expected}")
            print(f"      actual:   {actual}")
            fail += 1
    return ok, fail


# ── EC key-based signing ──────────────────────────────────────────────────────

def generate_key_pair(prefix: str) -> None:
    avail, mods = _try_import_cryptography()
    if not avail:
        print("ERROR: `cryptography` package required: pip install cryptography", file=sys.stderr)
        sys.exit(1)
    hashes, serialization, ec, _, _ = mods
    private_key = ec.generate_private_key(ec.SECP256R1())
    priv_pem = private_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )
    pub_pem = private_key.public_key().public_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    )
    Path(f"{prefix}.pem").write_bytes(priv_pem)
    Path(f"{prefix}.pub.pem").write_bytes(pub_pem)
    print(f"Key pair written:\n  private: {prefix}.pem\n  public:  {prefix}.pub.pem")


def sign_with_key(boms_dir: Path, private_key_path: Path) -> None:
    avail, mods = _try_import_cryptography()
    if not avail:
        print("ERROR: `cryptography` package required: pip install cryptography", file=sys.stderr)
        sys.exit(1)
    hashes, serialization, ec, _, _ = mods
    from cryptography.hazmat.primitives.asymmetric import ec as _ec  # noqa: F811

    priv_bytes = private_key_path.read_bytes()
    private_key = serialization.load_pem_private_key(priv_bytes, password=None)

    for bf in sorted(boms_dir.glob("*.cyclonedx.json")):
        data = bf.read_bytes()
        sig  = private_key.sign(data, _ec.ECDSA(hashes.SHA256()))
        sig_b64 = base64.b64encode(sig).decode()
        sig_path = bf.with_suffix(".json.sig")
        sig_path.write_text(sig_b64, encoding="utf-8")
        digest = hashlib.sha256(data).hexdigest()
        print(f"  ✓  signed {bf.name}  sha256={digest[:16]}…")
    print("Signatures written to *.cyclonedx.json.sig")


def verify_with_key(boms_dir: Path, public_key_path: Path) -> tuple[int, int]:
    avail, mods = _try_import_cryptography()
    if not avail:
        print("ERROR: `cryptography` package required: pip install cryptography", file=sys.stderr)
        sys.exit(1)
    hashes, serialization, ec, _, _ = mods
    from cryptography.hazmat.primitives.asymmetric import ec as _ec  # noqa: F811
    from cryptography.exceptions import InvalidSignature

    pub_bytes  = public_key_path.read_bytes()
    public_key = serialization.load_pem_public_key(pub_bytes)
    ok = fail = 0
    for bf in sorted(boms_dir.glob("*.cyclonedx.json")):
        sig_path = bf.with_suffix(".json.sig")
        if not sig_path.exists():
            print(f"  -  NO SIG  {bf.name}")
            continue
        sig = base64.b64decode(sig_path.read_text(encoding="utf-8").strip())
        try:
            public_key.verify(sig, bf.read_bytes(), _ec.ECDSA(hashes.SHA256()))
            print(f"  ✓  VALID   {bf.name}")
            ok += 1
        except InvalidSignature:
            print(f"  ✗  INVALID {bf.name}")
            fail += 1
        except Exception as exc:
            print(f"  ✗  ERROR   {bf.name}: {exc}")
            fail += 1
    return ok, fail


# ── Sigstore keyless signing ──────────────────────────────────────────────────

def sign_with_sigstore(boms_dir: Path) -> None:
    if not _try_import_sigstore():
        print("ERROR: `sigstore` package required: pip install sigstore", file=sys.stderr)
        sys.exit(1)
    import subprocess  # noqa: S404
    for bf in sorted(boms_dir.glob("*.cyclonedx.json")):
        result = subprocess.run(
            ["python3", "-m", "sigstore", "sign", "--output-bundle", str(bf) + ".sigstore", str(bf)],
            capture_output=True, text=True, check=False
        )
        if result.returncode == 0:
            print(f"  ✓  {bf.name} → {bf.name}.sigstore")
        else:
            print(f"  ✗  {bf.name}: {result.stderr.strip()}", file=sys.stderr)


def verify_with_sigstore(boms_dir: Path, cert_identity: str, cert_oidc_issuer: str) -> None:
    if not _try_import_sigstore():
        print("ERROR: `sigstore` package required: pip install sigstore", file=sys.stderr)
        sys.exit(1)
    import subprocess  # noqa: S404
    for bundle in sorted(boms_dir.glob("*.cyclonedx.json.sigstore")):
        bom_path = bundle.with_suffix("").with_suffix(".json")
        result = subprocess.run(
            ["python3", "-m", "sigstore", "verify", "identity",
             "--bundle", str(bundle),
             "--cert-identity", cert_identity,
             "--cert-oidc-issuer", cert_oidc_issuer,
             str(bom_path)],
            capture_output=True, text=True, check=False
        )
        status = "✓ VALID" if result.returncode == 0 else "✗ INVALID"
        print(f"  {status}  {bom_path.name}")
        if result.returncode != 0:
            print(f"           {result.stderr.strip()}", file=sys.stderr)


# ── main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(description="Sign and verify CycloneDX SBOMs")
    parser.add_argument("--boms-dir",      type=Path, default=BOMS_DIR_DEFAULT)
    parser.add_argument("--mode",          choices=["hash", "key", "sigstore"], default="hash",
                        help="Signing backend (default: hash manifest)")
    parser.add_argument("--verify",        action="store_true", help="Verify instead of sign")
    parser.add_argument("--generate-key",  action="store_true", help="Generate EC P-256 key pair and exit")
    parser.add_argument("--key-prefix",    default="sbom-signing", help="Prefix for generated key files")
    parser.add_argument("--private-key",   type=Path, help="PEM private key (for --mode key)")
    parser.add_argument("--public-key",    type=Path, help="PEM public key (for --mode key --verify)")
    # Sigstore options
    parser.add_argument("--cert-identity",     default="", help="Expected OIDC identity (sigstore verify)")
    parser.add_argument("--cert-oidc-issuer",  default="https://accounts.google.com",
                        help="Expected OIDC issuer URL (sigstore verify)")
    args = parser.parse_args()

    if args.generate_key:
        generate_key_pair(args.key_prefix)
        return

    if args.mode == "hash":
        if args.verify:
            ok, fail = verify_hash_manifest(args.boms_dir)
            print(f"\n  {ok} OK  {fail} FAILED")
            if fail:
                sys.exit(1)
        else:
            out = write_hash_manifest(args.boms_dir)
            print(f"Hash manifest written: {out}")

    elif args.mode == "key":
        if args.verify:
            if not args.public_key:
                parser.error("--public-key required for --mode key --verify")
            ok, fail = verify_with_key(args.boms_dir, args.public_key)
            print(f"\n  {ok} valid  {fail} invalid/missing")
            if fail:
                sys.exit(1)
        else:
            if not args.private_key:
                parser.error("--private-key required for --mode key")
            sign_with_key(args.boms_dir, args.private_key)

    elif args.mode == "sigstore":
        if args.verify:
            sign_with_sigstore(args.boms_dir)  # just calls verify sub-command
            verify_with_sigstore(args.boms_dir, args.cert_identity, args.cert_oidc_issuer)
        else:
            sign_with_sigstore(args.boms_dir)


if __name__ == "__main__":
    main()

