import unittest
from math import log10

import numpy as np

from core.signal_analysis import AmbientCalibrator, MainsInterferenceDetector


class AmbientCalibratorTests(unittest.TestCase):
    def test_calibrates_mean_and_subtracts_audio_background_after_ten_seconds(self):
        calibrator = AmbientCalibrator(duration_s=10)
        self.assertTrue(calibrator.start(100))
        self.assertFalse(calibrator.add(105, -50, None))
        self.assertTrue(calibrator.add(110, -40, None))
        expected_baseline = 10 * log10((10 ** (-5) + 10 ** (-4)) / 2)
        self.assertAlmostEqual(calibrator.baseline_audio, expected_baseline)
        self.assertIsNone(calibrator.baseline_mag)
        expected_corrected = 10 * log10(10 ** (-3.5) - 10 ** (expected_baseline / 10))
        self.assertAlmostEqual(calibrator.adjust_audio(-35), expected_corrected)
        self.assertEqual(calibrator.adjust_magnetic(None), None)
        self.assertIsNotNone(calibrator.completed_at)

    def test_refuses_to_complete_without_valid_audio_measurements(self):
        calibrator = AmbientCalibrator()
        calibrator.start(0)
        with self.assertRaisesRegex(ValueError, "No valid microphone"):
            calibrator.add(10, None)

    def test_calculates_magnetic_baseline_when_a_magnetometer_is_available(self):
        calibrator = AmbientCalibrator(duration_s=1)
        calibrator.start(0)
        calibrator.add(0.5, -40, 40)
        calibrator.add(1, -40, 60)

        self.assertEqual(calibrator.baseline_mag, 50)
        self.assertEqual(calibrator.adjust_magnetic(55), 5)


class MainsInterferenceDetectorTests(unittest.TestCase):
    def test_requires_persistent_mains_peak_and_clears_when_it_disappears(self):
        detector = MainsInterferenceDetector(persistence_frames=3, prominence_db=8)
        rate = 8000
        time = np.arange(4096) / rate
        signal = np.sin(2 * np.pi * 50 * time) + 0.001 * np.random.default_rng(1).normal(
            size=time.size
        )

        for _ in range(2):
            result = detector.update(signal, rate)
            self.assertFalse(result["detected"])

        result = detector.update(signal, rate)
        self.assertTrue(result["detected"])
        self.assertIn("Interferenza Rete Elettrica Rilevata (50Hz/60Hz)", result["warning"])
        self.assertTrue(any(abs(frequency - 50) < 3 for frequency in result["frequencies_hz"]))

        result = detector.update(np.zeros_like(signal), rate)
        self.assertFalse(result["detected"])

    def test_detects_60_hz_and_its_harmonic(self):
        detector = MainsInterferenceDetector(persistence_frames=1, prominence_db=8)
        rate = 8000
        time = np.arange(4096) / rate
        signal = np.sin(2 * np.pi * 60 * time) + 0.5 * np.sin(2 * np.pi * 120 * time)

        result = detector.update(signal, rate)

        self.assertTrue(result["detected"])
        self.assertTrue(any(abs(frequency - 60) < 3 for frequency in result["frequencies_hz"]))
        self.assertTrue(any(abs(frequency - 120) < 3 for frequency in result["frequencies_hz"]))


if __name__ == "__main__":
    unittest.main()
