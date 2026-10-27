import base64
import hashlib
import json
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path
from unittest.mock import patch

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from core import license_guard
from tools import keydigitale, license_tool


class VerifyLicenseTests(unittest.TestCase):
    def setUp(self):
        self.private_key = Ed25519PrivateKey.generate()
        self.hwid = "0123456789abcdef0123456789abcdef"
        public_key = self.private_key.public_key().public_bytes(
            serialization.Encoding.Raw,
            serialization.PublicFormat.Raw,
        )
        self.public_key_hex = public_key.hex()
        self.temp_dir = tempfile.TemporaryDirectory()
        self.license_path = Path(self.temp_dir.name) / "license.key"
        self.public_key_patch = patch.object(
            license_guard,
            "PUBLIC_KEY_HEX",
            self.public_key_hex,
        )
        self.public_key_patch.start()
        self.addCleanup(self.public_key_patch.stop)
        self.addCleanup(self.temp_dir.cleanup)

    def _write_license(self, hwid=None, expires=None, signature=None):
        licensed_hwid = hwid or self.hwid
        issued = "2026-01-01"
        payload = license_guard._canonical_payload(licensed_hwid, expires, issued)
        signed = signature or self.private_key.sign(payload)
        document = {
            "schema": 1,
            "hwid": licensed_hwid,
            "issued": issued,
            "expires": expires,
            "sig": base64.b64encode(signed).decode("ascii"),
        }
        self.license_path.write_text(json.dumps(document), encoding="utf-8")

    def test_accepts_valid_perpetual_license_for_this_device(self):
        self._write_license()

        with patch.object(license_guard, "compute_hwid", return_value=self.hwid):
            self.assertIsNone(license_guard.verify_license(self.license_path))

    def test_accepts_existing_license_signed_by_previous_public_key(self):
        previous_key = Ed25519PrivateKey.generate()
        previous_public_key = previous_key.public_key().public_bytes(
            serialization.Encoding.Raw,
            serialization.PublicFormat.Raw,
        ).hex()
        payload = license_guard._canonical_payload(self.hwid, None, "2026-01-01")
        self._write_license(signature=previous_key.sign(payload))

        with patch.object(license_guard, "PREVIOUS_PUBLIC_KEY_HEXES", (previous_public_key,)):
            with patch.object(license_guard, "compute_hwid", return_value=self.hwid):
                self.assertIsNone(license_guard.verify_license(self.license_path))

    def test_rejects_invalid_signature(self):
        self._write_license()
        document = json.loads(self.license_path.read_text(encoding="utf-8"))
        document["sig"] = base64.b64encode(b"x" * 64).decode("ascii")
        self.license_path.write_text(json.dumps(document), encoding="utf-8")

        with self.assertRaisesRegex(license_guard.LicenseError, "Firma licenza non valida"):
            license_guard.verify_license(self.license_path)

    def test_rejects_license_for_another_device(self):
        other_hwid = "fedcba9876543210fedcba9876543210"
        self._write_license(hwid=other_hwid)

        with patch.object(license_guard, "compute_hwid", return_value=self.hwid):
            with self.assertRaisesRegex(license_guard.LicenseError, "HWID non corrisponde"):
                license_guard.verify_license(self.license_path)

    def test_rejects_expired_license(self):
        self._write_license(expires="2000-01-01")

        with patch.object(license_guard, "compute_hwid", return_value=self.hwid):
            with self.assertRaisesRegex(license_guard.LicenseError, "Licenza scaduta"):
                license_guard.verify_license(self.license_path)

    def test_rejects_malformed_base64_signature(self):
        document = {
            "schema": 1,
            "hwid": self.hwid,
            "issued": "2026-01-01",
            "expires": None,
            "sig": "not base64!",
        }
        self.license_path.write_text(json.dumps(document), encoding="utf-8")

        with self.assertRaisesRegex(license_guard.LicenseError, "Errore verifica firma"):
            license_guard.verify_license(self.license_path)

    def test_configured_missing_license_does_not_fall_back_to_working_directory(self):
        missing_path = Path(self.temp_dir.name) / "missing.key"

        with patch.dict("os.environ", {"FD_LICENSE_FILE": str(missing_path)}):
            with self.assertRaisesRegex(license_guard.LicenseError, "File di licenza non trovato"):
                license_guard.verify_license()

    def test_rejects_legacy_cos_keymaker_token(self):
        self.license_path.write_text("ABCD1234-ABCD1234-ABCD1234-ABCD1234", encoding="utf-8")

        with self.assertRaisesRegex(license_guard.LicenseError, "Chiave di licenza alfanumerica"):
            license_guard.verify_license(self.license_path)

    def test_android_hwid_is_stable_and_normalized(self):
        expected = license_guard.compute_android_hwid("0123456789abcdef")

        self.assertEqual(
            expected,
            hashlib.sha256(b"FD-HWID-v1|android|0123456789abcdef").hexdigest()[:32],
        )
        self.assertEqual(len(expected), 32)
        self.assertEqual(expected, license_guard.compute_android_hwid(" 0123456789ABCDEF "))
        self.assertEqual(expected, license_guard.compute_hwid("0123456789abcdef"))

    def test_android_hwid_requires_a_valid_ssaid(self):
        for android_id in ("", "null", "1234", "0123456789abcdeg"):
            with self.subTest(android_id=android_id):
                with self.assertRaisesRegex(license_guard.LicenseError, "SSAID non valido"):
                    license_guard.compute_android_hwid(android_id)

    def test_android_requires_native_ssaid_instead_of_system_commands(self):
        with patch.object(license_guard, "_is_android", return_value=True):
            with patch.object(license_guard.subprocess, "check_output") as check_output:
                with self.assertRaisesRegex(license_guard.LicenseError, "API native Android"):
                    license_guard.compute_hwid()
        check_output.assert_not_called()

    def test_license_tool_rejects_malformed_hwid(self):
        private_key_path = Path(self.temp_dir.name) / "private.pem"
        private_key_path.write_bytes(
            self.private_key.private_bytes(
                serialization.Encoding.PEM,
                serialization.PrivateFormat.PKCS8,
                serialization.NoEncryption(),
            )
        )

        with self.assertRaisesRegex(SystemExit, "32 caratteri esadecimali"):
            license_tool.cmd_issue(Namespace(
                key=private_key_path,
                hwid="0123456789abcdef",
                expires=None,
                out=str(self.license_path),
            ))

    def test_license_tool_creates_verifiable_ed25519_json(self):
        private_key_path = Path(self.temp_dir.name) / "private.pem"
        private_key_path.write_bytes(
            self.private_key.private_bytes(
                serialization.Encoding.PEM,
                serialization.PrivateFormat.PKCS8,
                serialization.NoEncryption(),
            )
        )

        result = license_tool.cmd_issue(Namespace(
            key=private_key_path,
            hwid=self.hwid,
            expires=None,
            out=str(self.license_path),
        ))

        self.assertEqual(result, 0)
        self.assertIsInstance(json.loads(self.license_path.read_text(encoding="utf-8")), dict)
        with patch.object(license_guard, "compute_hwid", return_value=self.hwid):
            self.assertIsNone(license_guard.verify_license(self.license_path))

    def test_license_tool_creates_verifiable_alphanumeric_code(self):
        private_key_path = Path(self.temp_dir.name) / "private.pem"
        private_key_path.write_bytes(
            self.private_key.private_bytes(
                serialization.Encoding.PEM,
                serialization.PrivateFormat.PKCS8,
                serialization.NoEncryption(),
            )
        )

        code = license_tool.issue_license_code(private_key_path, self.hwid, None)
        self.assertRegex(code, r"^[A-Z2-7]+$")
        self.assertEqual(len(code), 140)
        self.license_path.write_text(code, encoding="ascii")

        with patch.object(license_guard, "compute_hwid", return_value=self.hwid):
            self.assertIsNone(license_guard.verify_license(self.license_path))

    def test_alphanumeric_code_accepts_spaces_and_lowercase(self):
        private_key_path = Path(self.temp_dir.name) / "private.pem"
        private_key_path.write_bytes(
            self.private_key.private_bytes(
                serialization.Encoding.PEM,
                serialization.PrivateFormat.PKCS8,
                serialization.NoEncryption(),
            )
        )
        code = license_tool.issue_license_code(private_key_path, self.hwid, None)
        spaced_code = " ".join(code[index:index + 10] for index in range(0, len(code), 10)).lower()
        self.license_path.write_text(spaced_code, encoding="ascii")

        with patch.object(license_guard, "compute_hwid", return_value=self.hwid):
            self.assertIsNone(license_guard.verify_license(self.license_path))

    def test_keydigitale_validates_expiry_format(self):
        self.assertIsNone(keydigitale.validate_expiry(""))
        self.assertEqual(keydigitale.validate_expiry(" 2026-12-31 "), "2026-12-31")

        with self.assertRaisesRegex(ValueError, "AAAA-MM-GG"):
            keydigitale.validate_expiry("31-12-2026")
