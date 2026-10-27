import numpy as np


class LorenzChaoticEngine:
    """
    Generatore basato sulle equazioni differenziali dell'Attrattore di Lorenz.
    Produce un flusso deterministico ma caotico (non ciclico) di frequenze digitali.
    """

    def __init__(self, sigma=10.0, beta=8.0 / 3.0, rho=28.0, dt=0.01):
        self.sigma = sigma
        self.beta = beta
        self.rho = rho
        self.dt = dt

        # Stato iniziale
        self.x = 0.1
        self.y = 0.0
        self.z = 0.0

    def step(self):
        """Calcola lo stato successivo e restituisce le coordinate."""
        dx = self.sigma * (self.y - self.x) * self.dt
        dy = (self.x * (self.rho - self.z) - self.y) * self.dt
        dz = (self.x * self.y - self.beta * self.z) * self.dt

        self.x += dx
        self.y += dy
        self.z += dz

        return self.x, self.y, self.z

    def get_frequency_multiplier(self, min_freq=100.0, max_freq=2000.0):
        """Mappa la coordinata x caotica su un intervallo di frequenza udibile."""
        self.step()
        normalized = np.clip((self.x + 20.0) / 40.0, 0.0, 1.0)

        return min_freq + normalized * (max_freq - min_freq)
