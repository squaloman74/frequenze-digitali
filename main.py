import asyncio
import json
import logging
import sys
import time

import sounddevice as sd

from backend.server import TelemetryServer
from core.audio_engine import AudioEngine
from core.chaotic_generator import LorenzChaoticEngine
from core.license_guard import LicenseError, verify_license
from core.microphone_monitor import MicrophoneMonitor
from core.signal_analysis import AmbientCalibrator, MainsInterferenceDetector

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
logger = logging.getLogger(__name__)


async def run():
    generator = LorenzChaoticEngine()
    audio_engine = AudioEngine(generator=generator)
    microphone = MicrophoneMonitor()
    calibrator = AmbientCalibrator(duration_s=10.0)
    interference_detector = MainsInterferenceDetector()
    calibration_requested = asyncio.Event()

    async def handle_control_message(message: str) -> None:
        try:
            request = json.loads(message)
        except json.JSONDecodeError as exc:
            raise ValueError("Control messages must be valid JSON.") from exc
        if not isinstance(request, dict) or request.get("type") != "calibrate":
            raise ValueError("Unsupported telemetry control message.")
        calibration_requested.set()

    telemetry_server = TelemetryServer(
        host="127.0.0.1",
        port=8765,
        on_message=handle_control_message,
    )

    try:
        await telemetry_server.start()
        audio_engine.start()
        try:
            microphone.start()
        except sd.PortAudioError as exc:
            logger.warning("Microphone unavailable; reporting no measurement: %s", exc)

        calibrator.start(time.monotonic())
        logger.info("Ambient calibration started (10 seconds).")
        was_interference_detected = False

        while True:
            if calibration_requested.is_set():
                calibration_requested.clear()
                calibrator.start(time.monotonic(), restart=True)
                logger.info("Ambient calibration restarted (10 seconds).")

            frequency = generator.get_frequency_multiplier(
                min_freq=150.0,
                max_freq=600.0,
            )
            audio_engine.set_frequency(frequency)
            microphone_raw_db = microphone.level_db
            calibration_error = None
            try:
                calibration_completed = calibrator.add(
                    time.monotonic(),
                    microphone_raw_db,
                    mag_ut=None,
                )
            except ValueError as exc:
                calibration_completed = False
                calibration_error = str(exc)
                logger.error("Ambient calibration failed: %s", calibration_error)
            if calibration_completed:
                logger.info(
                    "Ambient calibration completed at %s (audio baseline: %.2f dBFS; "
                    "magnetic baseline unavailable: no magnetometer detected).",
                    calibrator.completed_at,
                    calibrator.baseline_audio,
                )
            microphone_corrected_db = calibrator.adjust_audio(microphone_raw_db)

            # Campioni audio recenti dal buffer circolare del microfono.
            # Lista vuota se il microfono non e' disponibile.
            mic_samples = microphone.samples
            samples_block = (
                [round(float(v), 6) for v in mic_samples[-1024:]]
                if getattr(mic_samples, "size", 0)
                else []
            )
            interference = interference_detector.update(
                mic_samples,
                microphone.sample_rate,
            )
            events = []
            if calibration_completed:
                events.append({
                    "type": "calibration",
                    "msg": "Calibrazione ambientale completata.",
                    "at": calibrator.completed_at,
                })
            if calibration_error:
                events.append({
                    "type": "error",
                    "msg": f"Calibrazione non riuscita: {calibration_error}",
                })
            if interference["detected"] and not was_interference_detected:
                warning = str(interference["warning"])
                logger.warning("%s", warning)
                events.append({"type": "warning", "msg": warning})
            was_interference_detected = bool(interference["detected"])

            frame = {
                "schema_version": 1,
                "t": time.time(),
                "source": "live",
                "freq": frequency,
                "attractor": {
                    "x": generator.x,
                    "y": generator.y,
                    "z": generator.z,
                },
                "sensors": {
                    "mic_db": microphone_raw_db,
                    "mic_db_corrected": microphone_corrected_db,
                    "mag_ut": None,
                    "mag_ut_corrected": None,
                    "entropy": None,
                },
                "status": {
                    "calibrated": calibrator.calibrated,
                },
                "calibration": {
                    **calibrator.as_dict(),
                    "active": calibrator.active,
                    "error": calibration_error,
                },
                "interference": interference,
                "events": events,
                "provenance": {
                    "freq": "derived",
                    "attractor": "derived",
                    "sensors": {
                        "mic_db": (
                            "measured" if microphone_raw_db is not None else "unavailable"
                        ),
                        "mic_db_corrected": (
                            "derived" if microphone_corrected_db is not None else "unavailable"
                        ),
                        "mag_ut": "unavailable",
                        "mag_ut_corrected": "unavailable",
                        "entropy": "unavailable",
                    },
                    "status": {
                        "calibrated": "derived",
                    },
                },
                "samples": samples_block,
                "sample_rate": microphone.sample_rate,
            }
            await telemetry_server.publish(frame)
            await asyncio.sleep(0.05)
    finally:
        try:
            try:
                microphone.stop()
            finally:
                audio_engine.stop()
        finally:
            await telemetry_server.close()


def main():
    # --- Controllo licenza (bloccante) ---
    try:
        verify_license()
        logger.info("Licenza verificata con successo.")
    except LicenseError as e:
        logger.error("LICENZA NON VALIDA: %s", e)
        sys.exit(1)

    try:
        asyncio.run(run())
    except KeyboardInterrupt:
        logger.info("Shutdown requested")


if __name__ == "__main__":
    main()