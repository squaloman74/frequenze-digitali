"""Compact alphanumeric representation for signed device licenses."""
from __future__ import annotations

import base64
import binascii
import re
from datetime import date

TOKEN_VERSION = 1
TOKEN_SIZE = 1 + 16 + 3 + 3 + 64


def encode_license_code(
    hwid: str,
    issued: str,
    expires: str | None,
    signature: bytes,
) -> str:
    if re.fullmatch(r"[0-9a-f]{32}", hwid) is None:
        raise ValueError("HWID non valido.")
    if len(signature) != 64:
        raise ValueError("Firma Ed25519 non valida.")

    issued_ordinal = date.fromisoformat(issued).toordinal()
    expires_ordinal = date.fromisoformat(expires).toordinal() if expires else 0
    payload = (
        bytes([TOKEN_VERSION])
        + bytes.fromhex(hwid)
        + issued_ordinal.to_bytes(3, "big")
        + expires_ordinal.to_bytes(3, "big")
        + signature
    )
    return base64.b32encode(payload).decode("ascii").rstrip("=")


def decode_license_code(code: str) -> dict[str, str | None]:
    normalized = re.sub(r"[\s-]", "", code).upper()
    if re.fullmatch(r"[A-Z2-7]+", normalized) is None:
        raise ValueError("La chiave deve contenere solo lettere e numeri.")
    try:
        padded = normalized + "=" * ((8 - len(normalized) % 8) % 8)
        payload = base64.b32decode(padded, casefold=False)
    except (binascii.Error, ValueError) as exc:
        raise ValueError("Codice alfanumerico non valido.") from exc
    if len(payload) != TOKEN_SIZE or payload[0] != TOKEN_VERSION:
        raise ValueError("Formato o versione della chiave non supportati.")

    hwid = payload[1:17].hex()
    issued_ordinal = int.from_bytes(payload[17:20], "big")
    expires_ordinal = int.from_bytes(payload[20:23], "big")
    try:
        issued = date.fromordinal(issued_ordinal).isoformat()
        expires = date.fromordinal(expires_ordinal).isoformat() if expires_ordinal else None
    except ValueError as exc:
        raise ValueError("Date nel codice licenza non valide.") from exc

    return {
        "schema": TOKEN_VERSION,
        "hwid": hwid,
        "issued": issued,
        "expires": expires,
        "sig": base64.b64encode(payload[23:]).decode("ascii"),
    }
