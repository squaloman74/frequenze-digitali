"""Generatore di chiavi e licenze per Frequenze Digitali.

La chiave PRIVATA non deve MAI finire nel repository: usala solo sul tuo
computer (o in un HSM/CI sicuro) per firmare le licenze dei clienti.

Uso:
    # 1) Genera una coppia di chiavi (una sola volta)
    python tools/license_tool.py keygen --out <directory-esterna-al-progetto>

    # 2) Stampa la chiave pubblica in hex da incorporare in core/license_guard.py
    python tools/license_tool.py pubkey --key <directory-esterna>/license_private.pem

    # 3) Emetti una licenza per l'HWID di un cliente
    python tools/license_tool.py issue \
        --key <directory-esterna>/license_private.pem \
        --hwid <HWID_CLIENTE> \
        --expires 2026-12-31 \
        --out license.key
"""
from __future__ import annotations

import argparse
import base64
import json
import re
import sys
from datetime import date, datetime
from pathlib import Path

from core.license_format import encode_license_code

try:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import (
        Ed25519PrivateKey,
        Ed25519PublicKey,
    )
    from cryptography.hazmat.primitives.serialization import (
        Encoding,
        NoEncryption,
        PrivateFormat,
        PublicFormat,
    )
except ImportError:  # pragma: no cover
    sys.exit("Richiede 'cryptography': pip install cryptography")


# Domain-separation tag: impedisce il riuso della firma in altri contesti.
SIGN_CONTEXT = "FD-LICENSE-v1"
PROJECT_ROOT = Path(__file__).resolve().parents[1]


def _require_external_path(path: Path, project_root: Path = PROJECT_ROOT) -> Path:
    resolved = path.expanduser().resolve()
    try:
        resolved.relative_to(project_root.resolve())
    except ValueError:
        return resolved
    raise SystemExit("La chiave privata deve essere conservata fuori dalla directory del progetto.")


def _load_private_key(
    path: Path,
    project_root: Path = PROJECT_ROOT,
) -> Ed25519PrivateKey:
    data = _require_external_path(path, project_root).read_bytes()
    key = Ed25519PrivateKey.from_private_bytes(_pem_to_raw(data))
    return key


def _pem_to_raw(pem: bytes) -> bytes:
    # Le chiavi raw Ed25519 sono serializzate in PEM PKCS8; estraiamo i 32 byte.
    from cryptography.hazmat.primitives.serialization import load_pem_private_key
    key = load_pem_private_key(pem, password=None)
    return key.private_bytes(Encoding.Raw, PrivateFormat.Raw, NoEncryption())


def cmd_keygen(args: argparse.Namespace) -> int:
    priv_path, pub_hex_path, pub_hex = generate_keypair(Path(args.out), force=args.force)

    print(f"Chiave privata  : {priv_path}  (NON committare!)")
    print(f"Chiave pubblica : {pub_hex_path}")
    print(f"PUBLIC_KEY_HEX  -> {pub_hex}")
    return 0


def generate_keypair(
    out_dir: Path,
    *,
    force: bool = False,
    project_root: Path = PROJECT_ROOT,
) -> tuple[Path, Path, str]:
    out_dir = _require_external_path(out_dir, project_root)
    out_dir.mkdir(parents=True, exist_ok=True)
    priv_path = out_dir / "license_private.pem"
    pub_hex_path = out_dir / "license_public.hex"
    if (priv_path.exists() or pub_hex_path.exists()) and not force:
        raise FileExistsError(f"Le chiavi esistono già in {out_dir}; non verranno sovrascritte.")

    private_key = Ed25519PrivateKey.generate()
    pem = private_key.private_bytes(Encoding.PEM, PrivateFormat.PKCS8, NoEncryption())
    priv_path.write_bytes(pem)

    public_key = private_key.public_key()
    pub_hex = public_key.public_bytes(Encoding.Raw, PublicFormat.Raw).hex()
    pub_hex_path.write_text(pub_hex + "\n", encoding="utf-8")
    return priv_path, pub_hex_path, pub_hex


def cmd_pubkey(args: argparse.Namespace) -> int:
    key = _load_private_key(Path(args.key))
    pub_hex = key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw).hex()
    print(pub_hex)
    return 0


def _canonical_payload(hwid: str, expires: str | None, issued: str) -> bytes:
    """Serializzazione deterministica da firmare (ordine dei campi stabile)."""
    payload = {"ctx": SIGN_CONTEXT, "hwid": hwid, "issued": issued, "expires": expires}
    return json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")


def cmd_issue(args: argparse.Namespace) -> int:
    try:
        license_doc = issue_license(
            Path(args.key),
            args.hwid,
            args.expires,
            Path(args.out),
        )
    except ValueError as e:
        if str(e).startswith("HWID non valido:"):
            sys.exit(str(e))
        raise

    print(f"Licenza scritta : {args.out}")
    print(f"  hwid    : {license_doc['hwid']}")
    print(f"  expires : {license_doc['expires'] or 'perpetua'}")
    return 0


def issue_license(
    private_key_path: Path,
    hwid: str,
    expires: str | None,
    output_path: Path,
    *,
    project_root: Path = PROJECT_ROOT,
) -> dict[str, object]:
    key = _load_private_key(private_key_path, project_root)
    normalized_hwid = hwid.strip().lower()
    if re.fullmatch(r"[0-9a-f]{32}", normalized_hwid) is None:
        raise ValueError("HWID non valido: sono richiesti 32 caratteri esadecimali.")

    if expires:
        datetime.strptime(expires, "%Y-%m-%d")
    issued = date.today().isoformat()
    payload = _canonical_payload(normalized_hwid, expires, issued)
    signature = key.sign(payload)
    license_doc = {
        "schema": 1,
        "hwid": normalized_hwid,
        "issued": issued,
        "expires": expires,
        "sig": base64.b64encode(signature).decode("ascii"),
    }
    output_path.write_text(json.dumps(license_doc, indent=2), encoding="utf-8")
    return license_doc


def issue_license_code(
    private_key_path: Path,
    hwid: str,
    expires: str | None,
    *,
    project_root: Path = PROJECT_ROOT,
) -> str:
    key = _load_private_key(private_key_path, project_root)
    normalized_hwid = hwid.strip().lower()
    if re.fullmatch(r"[0-9a-f]{32}", normalized_hwid) is None:
        raise ValueError("HWID non valido: sono richiesti 32 caratteri esadecimali.")
    if expires:
        datetime.strptime(expires, "%Y-%m-%d")
    issued = date.today().isoformat()
    signature = key.sign(_canonical_payload(normalized_hwid, expires, issued))
    return encode_license_code(normalized_hwid, issued, expires, signature)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Gestione licenze Frequenze Digitali")
    sub = parser.add_subparsers(dest="command", required=True)

    p_keygen = sub.add_parser("keygen", help="Genera una coppia di chiavi Ed25519")
    p_keygen.add_argument(
        "--out",
        required=True,
        help="Cartella di output esterna al progetto",
    )
    p_keygen.add_argument("--force", action="store_true")
    p_keygen.set_defaults(func=cmd_keygen)

    p_pub = sub.add_parser("pubkey", help="Stampa la chiave pubblica in hex")
    p_pub.add_argument("--key", required=True, help="Percorso della chiave privata PEM")
    p_pub.set_defaults(func=cmd_pubkey)

    p_issue = sub.add_parser("issue", help="Firma una licenza")
    p_issue.add_argument("--key", required=True, help="Chiave privata PEM")
    p_issue.add_argument("--hwid", required=True, help="HWID del cliente")
    p_issue.add_argument("--expires", default=None, help="Data di scadenza YYYY-MM-DD (opz.)")
    p_issue.add_argument("--out", default="license.key", help="File di licenza di output")
    p_issue.set_defaults(func=cmd_issue)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())