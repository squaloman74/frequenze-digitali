"""Modulo di protezione licenza basato su HWID + firma Ed25519.

Cross-platform (Windows, Linux, macOS, Android).
"""
from __future__ import annotations

import base64
import binascii
import hashlib
import json
import os
import platform
import re
import socket
import subprocess
import sys
from datetime import date, datetime
from pathlib import Path
from typing import Optional

from core.license_format import decode_license_code

try:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    from cryptography.exceptions import InvalidSignature
except ImportError:  # pragma: no cover
    sys.exit("[license_guard] 'cryptography' richiesto: pip install cryptography")


# =====================================================================
# CHIAVE PUBBLICA ED25519 (32 byte, hex) - da sostituire con la tua.
# Generata con: python tools/license_tool.py pubkey --key <percorso-esterno>/license_private.pem
# NON committare mai la chiave privata!
# =====================================================================
PUBLIC_KEY_HEX = "565ffe0474961e868c5e613eff739aa4e7593dabdadf4fec3e5693eb5036f723"
PREVIOUS_PUBLIC_KEY_HEXES = (
    "c578eef1f4dccd3de39b0c28f7b529c0c0ccf6cf57fc92ea5f130f6c2916a4b1",
    "3dfd19df472615229e73bfc9834b03a78d3f2492a09f66a8d9fddb67218d11f4",
)

# File di licenza atteso accanto al bootstrap (o in CWD)
LICENSE_FILENAME = "license.key"

# Contesto di firma - DEVE coincidere con quello in tools/license_tool.py
SIGN_CONTEXT = "FD-LICENSE-v1"

class LicenseError(Exception):
    """Errore di licenza con messaggio utente chiaro."""
    pass


def _get_windows_uuid() -> Optional[str]:
    """Win32_ComputerSystemProduct UUID (WMIC) - stabile per scheda madre."""
    try:
        out = subprocess.check_output(
            ["wmic", "csproduct", "get", "UUID"],
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=3,
        )
        for line in out.splitlines():
            line = line.strip()
            if line and line.lower() != "uuid":
                return line.lower()
    except (OSError, subprocess.SubprocessError, UnicodeError):
        pass
    return None


def _get_linux_machine_id() -> Optional[str]:
    """/etc/machine-id (systemd) o /var/lib/dbus/machine-id."""
    for p in ("/etc/machine-id", "/var/lib/dbus/machine-id"):
        try:
            txt = Path(p).read_text(encoding="utf-8").strip()
            if txt:
                return txt.lower()
        except (OSError, UnicodeError):
            pass
    return None


def _get_darwin_platform_uuid() -> Optional[str]:
    """IOPlatformUUID su macOS."""
    try:
        out = subprocess.check_output(
            ["ioreg", "-d2", "-c", "IOPlatformExpertDevice"],
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=3,
        )
        for line in out.splitlines():
            if "IOPlatformUUID" in line:
                return line.split("=")[-1].strip().strip('"').lower()
    except (OSError, subprocess.SubprocessError, UnicodeError):
        pass
    return None


def _get_fallback_components() -> list[str]:
    """Componenti di fallback sempre disponibili (hostname, CPU info generiche)."""
    comps = []
    try:
        comps.append(socket.gethostname().lower())
    except OSError:
        pass
    try:
        comps.append(platform.processor().lower())
    except (OSError, ValueError):
        pass
    try:
        comps.append(platform.machine().lower())
    except (OSError, ValueError):
        pass
    # /proc/cpuinfo serial (Linux ARM/RPi) o dmidecode (richiede root)
    try:
        if Path("/proc/cpuinfo").exists():
            txt = Path("/proc/cpuinfo").read_text(encoding="utf-8", errors="ignore")
            for line in txt.splitlines():
                if line.lower().startswith("serial"):
                    comps.append(line.split(":")[-1].strip().lower())
                    break
    except (OSError, UnicodeError):
        pass
    return [c for c in comps if c]


def _is_android() -> bool:
    return (
        sys.platform == "android"
        or hasattr(sys, "getandroidapilevel")
        or bool(os.environ.get("ANDROID_ROOT") and os.environ.get("ANDROID_DATA"))
    )


def compute_android_hwid(android_id: str) -> str:
    """Derive the 32-hex HWID from Android's app-scoped SSAID.

    Flutter/native callers must normalize the SSAID to lowercase and use the
    same ``FD-HWID-v1|android|`` prefix before SHA-256.
    """
    normalized_id = android_id.strip().lower() if isinstance(android_id, str) else ""
    if re.fullmatch(r"[0-9a-f]{16}", normalized_id) is None:
        raise LicenseError("Android SSAID non valido o non disponibile.")
    value = f"FD-HWID-v1|android|{normalized_id}"
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:32]


def compute_hwid(android_id: Optional[str] = None) -> str:
    """
    Calcola un HWID deterministico per il sistema desktop o Android.
    Strategia: raccoglie tutti gli identificatori disponibili per la piattaforma,
    li ordina, li concatena con '|' e ne calcola SHA-256 (primi 32 char hex).
    Android riceve l'SSAID dalle API native e non esegue comandi di sistema.
    """
    if android_id is not None:
        return compute_android_hwid(android_id)
    if _is_android():
        raise LicenseError(
            "Android SSAID non disponibile: passalo dalle API native Android."
        )

    system = platform.system().lower()
    parts: list[str] = []

    if system == "windows":
        uuid = _get_windows_uuid()
        if uuid:
            parts.append(f"wmic:{uuid}")
    elif system == "linux":
        mid = _get_linux_machine_id()
        if mid:
            parts.append(f"machine-id:{mid}")
    elif system == "darwin":
        uuid = _get_darwin_platform_uuid()
        if uuid:
            parts.append(f"platform-uuid:{uuid}")

    # Fallback cross-platform
    for c in _get_fallback_components():
        parts.append(f"fallback:{c}")

    if not parts:
        raise LicenseError(
            "Impossibile determinare un identificativo stabile per questo dispositivo."
        )

    parts.sort()
    combined = "|".join(parts)
    return hashlib.sha256(combined.encode("utf-8")).hexdigest()[:32]


def _load_public_keys() -> tuple[Ed25519PublicKey, ...]:
    """Load the current and retained Ed25519 verification keys."""
    keys = []
    for key_hex in (PUBLIC_KEY_HEX, *PREVIOUS_PUBLIC_KEY_HEXES):
        try:
            raw = bytes.fromhex(key_hex)
            if len(raw) != 32:
                raise ValueError
        except (TypeError, ValueError) as e:
            raise LicenseError(
                "Chiave pubblica non configurata correttamente in core/license_guard.py."
            ) from e
        keys.append(Ed25519PublicKey.from_public_bytes(raw))
    return tuple(keys)


def _canonical_payload(hwid: str, expires: Optional[str], issued: str) -> bytes:
    """Ricostruisce il payload esatto che è stato firmato (ordine stabile)."""
    payload = {"ctx": SIGN_CONTEXT, "hwid": hwid, "issued": issued, "expires": expires}
    return json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")


def verify_license(license_path: Optional[Path] = None) -> None:
    """
    Verifica il file di licenza locale.
    Solleva LicenseError con messaggio chiaro se non valida.
    """
    # 1) Trova il file di licenza
    explicit_path = license_path is not None
    configured_path = os.environ.get("FD_LICENSE_FILE") if license_path is None else None
    if license_path is None:
        license_path = (
            Path(configured_path)
            if configured_path
            else Path.cwd() / LICENSE_FILENAME
        )
    if not license_path.exists():
        if explicit_path or configured_path:
            raise LicenseError(f"File di licenza non trovato: '{license_path}'")
        # Prova anche accanto a questo modulo
        license_path = Path(__file__).with_name(LICENSE_FILENAME)
        if not license_path.exists():
            raise LicenseError(
                f"File di licenza non trovato: '{LICENSE_FILENAME}' "
                "nel working directory o accanto a core/license_guard.py"
            )

    # 2) Load JSON licenses and compact alphanumeric license codes.
    try:
        license_text = license_path.read_text(encoding="utf-8")
    except FileNotFoundError:
        raise LicenseError(f"File di licenza non trovato: '{license_path}'")
    except (OSError, UnicodeError) as e:
        raise LicenseError(f"Licenza illeggibile (JSON invalido): {e}")

    try:
        doc = json.loads(license_text)
    except json.JSONDecodeError:
        try:
            doc = decode_license_code(license_text)
        except ValueError as exc:
            raise LicenseError(f"Chiave di licenza alfanumerica non valida: {exc}") from exc

    if not isinstance(doc, dict):
        raise LicenseError("Licenza invalida: il contenuto deve essere un oggetto JSON.")

    # 3) Campi obbligatori
    required = ("schema", "hwid", "issued", "sig")
    for k in required:
        if k not in doc:
            raise LicenseError(f"Licenza invalida: campo mancante '{k}'")

    if type(doc["schema"]) is not int or doc["schema"] != 1:
        raise LicenseError(f"Versione schema licenza non supportata: {doc['schema']}")

    if not isinstance(doc["hwid"], str):
        raise LicenseError("Licenza invalida: 'hwid' deve essere una stringa.")
    licensed_hwid = doc["hwid"].strip().lower()
    if re.fullmatch(r"[0-9a-f]{32}", licensed_hwid) is None:
        raise LicenseError("Licenza invalida: formato HWID non valido.")

    if not isinstance(doc["issued"], str):
        raise LicenseError("Licenza invalida: 'issued' deve essere una data YYYY-MM-DD.")
    issued = doc["issued"]
    try:
        datetime.strptime(issued, "%Y-%m-%d")
    except ValueError:
        raise LicenseError(f"Formato data emissione non valido: {issued}")

    expires = doc.get("expires")
    if expires is not None:
        if not isinstance(expires, str):
            raise LicenseError("Licenza invalida: 'expires' deve essere una data YYYY-MM-DD o null.")
        try:
            exp_date = datetime.strptime(expires, "%Y-%m-%d").date()
        except ValueError:
            raise LicenseError(f"Formato data scadenza non valido: {expires}")

    if not isinstance(doc["sig"], str):
        raise LicenseError("Licenza invalida: 'sig' deve essere una stringa base64.")

    payload = _canonical_payload(
        hwid=licensed_hwid,
        expires=expires,
        issued=issued,
    )
    try:
        signature = base64.b64decode(doc["sig"], validate=True)
        if len(signature) != 64:
            raise ValueError("lunghezza firma Ed25519 non valida")
        for public_key in _load_public_keys():
            try:
                public_key.verify(signature, payload)
                break
            except InvalidSignature:
                continue
        else:
            raise LicenseError(
                "Firma licenza non valida: la licenza potrebbe essere corrotta o manomessa."
            )
    except InvalidSignature:
        raise LicenseError(
            "Firma licenza non valida: la licenza potrebbe essere corrotta o manomessa."
        )
    except (binascii.Error, ValueError) as e:
        raise LicenseError(f"Errore verifica firma: {e}")

    # 4) HWID match, dopo aver autenticato i campi della licenza.
    local_hwid = compute_hwid()
    if local_hwid != licensed_hwid:
        raise LicenseError(
            f"HWID non corrisponde.\n"
            f"  Questo dispositivo : {local_hwid}\n"
            f"  Licenza autorizza : {licensed_hwid}\n"
            f"Ottieni una licenza per questo hardware."
        )

    # 5) Scadenza.
    if expires is not None and date.today() > exp_date:
        raise LicenseError(
            f"Licenza scaduta il {expires} (oggi: {date.today().isoformat()})."
        )


def main(argv: Optional[list[str]] = None) -> int:
    """Entry point CLI used by the desktop activation screen."""
    import argparse

    parser = argparse.ArgumentParser(description="Verifica licenza Frequenze Digitali")
    action = parser.add_mutually_exclusive_group()
    action.add_argument(
        "--hwid",
        action="store_true",
        help="stampa l'HWID del dispositivo per richiedere una licenza",
    )
    action.add_argument(
        "--license",
        type=Path,
        help="verifica il file di licenza indicato",
    )
    args = parser.parse_args(argv)

    if args.hwid:
        try:
            print(compute_hwid())
            return 0
        except LicenseError as e:
            print(f"ERRORE HWID: {e}", file=sys.stderr)
            return 1

    try:
        verify_license(args.license)
        hwid = compute_hwid()
        print(f"OK Licenza valida per HWID: {hwid}")
        return 0
    except LicenseError as e:
        print(f"ERRORE LICENZA NON VALIDA: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())