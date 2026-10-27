import logging
from collections import deque

import numpy as np


logger = logging.getLogger(__name__)


class MicrophoneMonitor:
    """Capture the default input device and expose its RMS level in dBFS."""

    def __init__(self, sample_rate=44100, block_size=2048, n_samples_to_buffer=8192):
        if sample_rate <= 0:
            raise ValueError("sample_rate must be greater than zero")
        if block_size <= 0:
            raise ValueError("block_size must be greater than zero")
        if n_samples_to_buffer <= 0:
            raise ValueError("n_samples_to_buffer must be greater than zero")

        self.sample_rate = sample_rate
        self.block_size = block_size
        self._stream = None
        self._latest_db = None
        self._samples_buffer = deque(maxlen=n_samples_to_buffer)

    @property
    def is_running(self):
        return self._stream is not None and self._stream.active

    @property
    def level_db(self):
        return self._latest_db

    @property
    def samples(self):
        """Return a copy of the most recent audio samples (float64, range -1..1)."""
        return np.array(self._samples_buffer, dtype=np.float64)

    def start(self):
        """Start capturing from the system's default microphone."""
        if self._stream is not None:
            return

        import sounddevice as sd

        stream = sd.InputStream(
            samplerate=self.sample_rate,
            blocksize=self.block_size,
            channels=1,
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
        """Stop microphone capture and release the input device."""
        stream = self._stream
        if stream is None:
            return

        self._stream = None
        try:
            stream.stop()
        finally:
            stream.close()

    def _audio_callback(self, indata, frames, time_info, status):
        if status:
            logger.debug("Microphone stream status: %s", status)
        if frames == 0:
            return

        samples = np.asarray(indata, dtype=np.float64)
        if not np.isfinite(samples).all():
            self._latest_db = None
            logger.warning("Microphone provided non-finite samples")
            return

        self._samples_buffer.extend(samples.flatten())

        rms = float(np.sqrt(np.mean(np.square(samples))))
        self._latest_db = 20.0 * np.log10(max(rms, 1e-12))