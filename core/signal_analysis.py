"""Small, testable calibration and mains-interference helpers."""
from __future__ import annotations

from datetime import datetime
from math import fsum, log10

import numpy as np


class AmbientCalibrator:
    def __init__(self, duration_s: float = 10.0) -> None:
        if duration_s <= 0:
            raise ValueError("Calibration duration must be positive.")
        self.duration_s = duration_s
        self.started_at: float | None = None
        self.completed_at: str | None = None
        self.baseline_audio: float | None = None
        self.baseline_mag: float | None = None
        self._audio_powers: list[float] = []
        self._mag_values: list[float] = []

    @property
    def active(self) -> bool:
        return self.started_at is not None and self.baseline_audio is None

    @property
    def calibrated(self) -> bool:
        return self.baseline_audio is not None

    def start(self, now: float, *, restart: bool = False) -> bool:
        if self.active and not restart:
            return False
        self.started_at = now
        self.completed_at = None
        self.baseline_audio = None
        self.baseline_mag = None
        self._audio_powers.clear()
        self._mag_values.clear()
        return True

    def add(self, now: float, audio_db: float | None, mag_ut: float | None = None) -> bool:
        if not self.active:
            return False
        if audio_db is not None and np.isfinite(audio_db):
            self._audio_powers.append(10.0 ** (float(audio_db) / 10.0))
        if mag_ut is not None and np.isfinite(mag_ut):
            self._mag_values.append(float(mag_ut))
        if now - self.started_at < self.duration_s:
            return False
        if not self._audio_powers:
            self.started_at = None
            raise ValueError("No valid microphone measurements were captured during calibration.")

        mean_audio_power = fsum(self._audio_powers) / len(self._audio_powers)
        self.baseline_audio = 10.0 * log10(max(mean_audio_power, 1e-24))
        self.baseline_mag = (
            fsum(self._mag_values) / len(self._mag_values) if self._mag_values else None
        )
        self.completed_at = datetime.now().astimezone().isoformat(timespec="seconds")
        return True

    def adjust_audio(self, audio_db: float | None) -> float | None:
        if audio_db is None or self.baseline_audio is None:
            return audio_db
        measured_power = 10.0 ** (float(audio_db) / 10.0)
        baseline_power = 10.0 ** (self.baseline_audio / 10.0)
        return 10.0 * log10(max(measured_power - baseline_power, 1e-24))

    def adjust_magnetic(self, mag_ut: float | None) -> float | None:
        if mag_ut is None or self.baseline_mag is None:
            return mag_ut
        return float(mag_ut) - self.baseline_mag

    def as_dict(self) -> dict[str, float | str | None]:
        return {
            "baseline_audio": self.baseline_audio,
            "baseline_mag": self.baseline_mag,
            "completed_at": self.completed_at,
            "duration_s": self.duration_s,
        }


class MainsInterferenceDetector:
    def __init__(
        self,
        *,
        persistence_frames: int = 3,
        prominence_db: float = 10.0,
        max_harmonic: int = 5,
    ) -> None:
        self.persistence_frames = persistence_frames
        self.prominence_db = prominence_db
        self.max_harmonic = max_harmonic
        self._consecutive_hits = 0
        self.detected = False
        self.frequencies_hz: list[float] = []

    def update(self, samples: np.ndarray, sample_rate: float) -> dict[str, object]:
        values = np.asarray(samples, dtype=np.float64).reshape(-1)
        found: list[float] = []
        if values.size >= 256 and sample_rate > 0 and np.isfinite(values).all():
            centered = values - np.mean(values)
            spectrum = np.abs(np.fft.rfft(centered * np.hanning(values.size)))
            frequencies = np.fft.rfftfreq(values.size, d=1.0 / sample_rate)
            resolution = sample_rate / values.size
            targets = {
                float(base * harmonic)
                for base in (50, 60)
                for harmonic in range(1, self.max_harmonic + 1)
                if base * harmonic < sample_rate / 2
            }
            for target in sorted(targets):
                center = int(round(target / resolution))
                radius = max(1, int(np.ceil(2.0 / resolution)))
                start = max(1, center - radius)
                end = min(spectrum.size, center + radius + 1)
                if end <= start:
                    continue
                peak_index = start + int(np.argmax(spectrum[start:end]))
                peak = spectrum[peak_index]
                background_start = max(1, peak_index - 6)
                background_end = min(spectrum.size, peak_index + 7)
                background = np.concatenate(
                    (spectrum[background_start:max(background_start, peak_index - 2)],
                     spectrum[min(background_end, peak_index + 3):background_end])
                )
                if background.size == 0:
                    continue
                floor = float(np.median(background))
                if peak > 0 and 20 * np.log10(peak / max(floor, 1e-12)) >= self.prominence_db:
                    found.append(float(frequencies[peak_index]))

        if found:
            self._consecutive_hits += 1
        else:
            self._consecutive_hits = 0
        self.detected = self._consecutive_hits >= self.persistence_frames
        self.frequencies_hz = found if self.detected else []
        return {
            "detected": self.detected,
            "frequencies_hz": self.frequencies_hz,
            "warning": (
                "Interferenza Rete Elettrica Rilevata (50Hz/60Hz)"
                if self.detected
                else None
            ),
        }
