import logging

import numpy as np

from core.chaotic_generator import LorenzChaoticEngine


logger = logging.getLogger(__name__)

MIN_FREQUENCY = 150.0
MAX_FREQUENCY = 600.0
MASTER_GAIN = 0.05


class AudioEngine:
    """Generate a continuous sine tone whose pitch follows the Lorenz engine."""

    def __init__(
        self,
        sample_rate=44100,
        block_size=1024,
        channels=1,
        amplitude=0.2,
        generator=None,
        is_muted=True,
    ):
        if sample_rate <= 0:
            raise ValueError("sample_rate must be greater than zero")
        if block_size <= 0:
            raise ValueError("block_size must be greater than zero")
        if channels <= 0:
            raise ValueError("channels must be greater than zero")
        if not 0.0 <= amplitude <= 1.0:
            raise ValueError("amplitude must be between 0.0 and 1.0")

        self.sample_rate = sample_rate
        self.block_size = block_size
        self.channels = channels
        self.amplitude = amplitude
        self.is_muted = bool(is_muted)
        self.generator = generator or LorenzChaoticEngine()

        self._phase = 0.0
        self._frequency = 100.0
        self._requested_frequency = None
        self._stream = None

    @property
    def is_running(self):
        return self._stream is not None

    def set_frequency(self, frequency):
        """Set the target playback frequency in hertz."""
        if not np.isfinite(frequency) or frequency <= 0:
            raise ValueError("frequency must be a finite value greater than zero")

        self._requested_frequency = float(
            np.clip(frequency, MIN_FREQUENCY, MAX_FREQUENCY)
        )

    def set_muted(self, is_muted):
        """Toggle output silence without stopping audio processing or telemetry."""
        self.is_muted = bool(is_muted)

    def start(self):
        """Start audio playback; requires the optional ``sounddevice`` package."""
        if self.is_running:
            return

        import sounddevice as sd

        stream = sd.OutputStream(
            samplerate=self.sample_rate,
            blocksize=self.block_size,
            channels=self.channels,
            dtype="float32",
            callback=self._audio_callback,
        )
        try:
            stream.start()
        except Exception:
            stream.close()
            raise
        self._stream = stream

    def stop(self):
        """Stop playback and release the audio stream."""
        stream = self._stream
        if stream is None:
            return

        self._stream = None
        try:
            stream.stop()
        finally:
            stream.close()

    def _audio_callback(self, outdata, frames, time_info, status):
        if status:
            logger.warning("Audio stream status: %s", status)

        if frames == 0:
            return

        target_frequency = self._requested_frequency
        if target_frequency is None:
            target_frequency = self.generator.get_frequency_multiplier(
                min_freq=MIN_FREQUENCY,
                max_freq=MAX_FREQUENCY,
            )
        target_frequency = float(
            np.clip(target_frequency, MIN_FREQUENCY, MAX_FREQUENCY)
        )
        frequencies = np.linspace(
            self._frequency,
            target_frequency,
            frames,
            dtype=np.float64,
        )
        phase_steps = (2.0 * np.pi * frequencies) / self.sample_rate
        phases = self._phase + np.cumsum(phase_steps)
        signal = self.amplitude * MASTER_GAIN * np.sin(phases)

        if self.is_muted:
            outdata.fill(0.0)
        else:
            outdata[:] = signal[:, np.newaxis]
        self._phase = phases[-1] % (2.0 * np.pi)
        self._frequency = target_frequency
