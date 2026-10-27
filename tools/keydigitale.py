"""Interfaccia grafica per emettere licenze Frequenze Digitali."""
from __future__ import annotations

import argparse
import os
import sys
import tkinter as tk
from datetime import datetime
from pathlib import Path
from tkinter import filedialog, messagebox, ttk

from tools.license_tool import PROJECT_ROOT, issue_license_code


def resource_path(relative_path: str) -> Path:
    bundle_root = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parents[1]))
    return bundle_root / relative_path


def validate_expiry(value: str) -> str | None:
    expiry = value.strip()
    if not expiry:
        return None
    try:
        datetime.strptime(expiry, "%Y-%m-%d")
    except ValueError as exc:
        raise ValueError("La scadenza deve essere nel formato AAAA-MM-GG.") from exc
    return expiry


class KeyDigitaleApp:
    def __init__(self, root: tk.Tk, hwid: str = "") -> None:
        self.root = root
        default_project_root = (
            Path(sys.executable).resolve().parent if getattr(sys, "frozen", False) else PROJECT_ROOT
        )
        self.project_root = Path(
            os.environ.get("FD_LICENSE_PROJECT_ROOT", str(default_project_root))
        ).resolve()
        self.signing_key_path = Path(
            os.environ.get(
                "FD_KEYDIGITALE_PRIVATE_KEY",
                r"D:\keydigitale-private\license_private.pem",
            )
        )
        self.root.title("keydigitale | Frequenze Digitali")
        self.root.geometry("620x650")
        self.root.minsize(560, 610)
        self.root.configure(bg="#0e0e10")
        self.root.option_add("*Font", ("Segoe UI", 10))

        icon_path = resource_path("frontend/assets/frequenze-digitali.ico")
        if icon_path.exists():
            self.root.iconbitmap(str(icon_path))

        self.hwid = tk.StringVar(value=hwid)
        self.expires = tk.StringVar()
        self.status = tk.StringVar(value="ID dispositivo ricevuto." if hwid else "Inserisci l'ID dispositivo.")

        self._configure_style()
        self._build_header()
        self._build_license_form()
        ttk.Label(root, textvariable=self.status, style="Status.TLabel").pack(
            fill="x", padx=28, pady=(8, 16)
        )

    def _configure_style(self) -> None:
        style = ttk.Style(self.root)
        style.theme_use("clam")
        style.configure(".", background="#131316", foreground="#c9d1d3")
        style.configure("TFrame", background="#131316")
        style.configure("Card.TLabelframe", background="#131316", foreground="#00ffcc")
        style.configure(
            "Card.TLabelframe.Label",
            background="#131316",
            foreground="#00ffcc",
            font=("Segoe UI", 11, "bold"),
        )
        style.configure("TLabel", background="#131316", foreground="#c9d1d3")
        style.configure("Hint.TLabel", foreground="#92999c", font=("Segoe UI", 9))
        style.configure("Status.TLabel", background="#0e0e10", foreground="#00ffcc")
        style.configure("TEntry", fieldbackground="#0e0e10", foreground="#c9d1d3")
        style.configure("TButton", padding=(10, 7))
        style.configure(
            "Accent.TButton",
            background="#00ffcc",
            foreground="#0e0e10",
            font=("Segoe UI", 10, "bold"),
        )
        style.map("Accent.TButton", background=[("active", "#73ffe4")])

    def _build_header(self) -> None:
        header = ttk.Frame(self.root)
        header.pack(fill="x", padx=28, pady=(22, 18))
        logo_path = resource_path("frontend/assets/lorenz-circle.png")
        if logo_path.exists():
            self.logo = tk.PhotoImage(file=str(logo_path))
            scale = max(1, (self.logo.width() + 79) // 80)
            if scale > 1:
                self.logo = self.logo.subsample(scale, scale)
            ttk.Label(header, image=self.logo).pack(side="left", padx=(0, 14))

        title_frame = ttk.Frame(header)
        title_frame.pack(side="left", fill="y", pady=5)
        ttk.Label(
            title_frame,
            text="keydigitale",
            foreground="#00ffcc",
            font=("Segoe UI", 21, "bold"),
        ).pack(anchor="w")
        ttk.Label(
            title_frame,
            text="FREQUENZE DIGITALI · GENERA LICENZA",
            style="Hint.TLabel",
        ).pack(anchor="w", pady=(2, 0))

    def _build_license_form(self) -> None:
        card = ttk.LabelFrame(
            self.root,
            text="  Firma la licenza per questo dispositivo  ",
            style="Card.TLabelframe",
            padding=18,
        )
        card.pack(fill="both", expand=True, padx=28, pady=8)
        ttk.Label(card, text="ID DEL DISPOSITIVO").pack(anchor="w")
        ttk.Entry(card, textvariable=self.hwid).pack(fill="x", pady=(5, 16))
        ttk.Label(
            card,
            text="SCADENZA (AAAA-MM-GG; lascia vuoto per una licenza senza scadenza)",
        ).pack(anchor="w")
        ttk.Entry(card, textvariable=self.expires).pack(fill="x", pady=(5, 20))
        ttk.Button(
            card,
            text="Genera codice licenza",
            command=self.issue,
            style="Accent.TButton",
        ).pack(fill="x")
        ttk.Label(card, text="CODICE ALFANUMERICO").pack(anchor="w", pady=(16, 5))
        self.code_output = tk.Text(
            card,
            height=5,
            wrap="word",
            state="disabled",
            bg="#0e0e10",
            fg="#00ffcc",
            insertbackground="#00ffcc",
            relief="flat",
            padx=8,
            pady=8,
            font=("Consolas", 10),
        )
        self.code_output.pack(fill="x")
        actions = ttk.Frame(card)
        actions.pack(fill="x", pady=(8, 0))
        ttk.Button(
            actions,
            text="Copia codice",
            command=self.copy_code,
        ).pack(side="left", expand=True, fill="x", padx=(0, 4))
        ttk.Button(
            actions,
            text="Salva .key",
            command=self.save_code,
        ).pack(side="left", expand=True, fill="x", padx=(4, 0))
        ttk.Label(
            card,
            text="Il codice generato appare qui ed è pronto da copiare nell’applicazione.",
            style="Hint.TLabel",
        ).pack(anchor="w", pady=(12, 0))

    def issue(self) -> None:
        try:
            license_code = issue_license_code(
                self.signing_key_path,
                self.hwid.get(),
                validate_expiry(self.expires.get()),
                project_root=self.project_root,
            )
        except (OSError, ValueError, TypeError) as exc:
            messagebox.showerror(
                "Licenza non generata",
                f"{exc}\n\nPercorso chiave privata:\n{self.signing_key_path}",
                parent=self.root,
            )
            return

        self.code_output.configure(state="normal")
        self.code_output.delete("1.0", "end")
        self.code_output.insert("1.0", license_code)
        self.code_output.configure(state="disabled")
        self.root.clipboard_clear()
        self.root.clipboard_append(license_code)
        self.status.set("Codice licenza generato e copiato negli appunti.")
        messagebox.showinfo(
            "Licenza pronta",
            "Il codice è visibile nel generatore ed è stato copiato negli appunti.",
            parent=self.root,
        )

    def copy_code(self) -> None:
        code = self.code_output.get("1.0", "end").strip()
        if not code:
            messagebox.showinfo("Nessun codice", "Genera prima una licenza.", parent=self.root)
            return
        self.root.clipboard_clear()
        self.root.clipboard_append(code)
        self.status.set("Codice licenza copiato negli appunti.")

    def save_code(self) -> None:
        license_code = self.code_output.get("1.0", "end").strip()
        if not license_code:
            messagebox.showinfo("Nessun codice", "Genera prima una licenza.", parent=self.root)
            return
        output_path = filedialog.asksaveasfilename(
            parent=self.root,
            title="Salva licenza",
            initialfile="license.key",
            defaultextension=".key",
            filetypes=(("Licenza Frequenze Digitali", "*.key"), ("File di testo", "*.txt")),
        )
        if not output_path:
            return
        if Path(output_path).exists() and not messagebox.askyesno(
            "Sostituisci file?",
            f"Il file esiste già:\n{output_path}\n\nVuoi sostituirlo?",
            icon="warning",
            parent=self.root,
        ):
            return

        try:
            Path(output_path).write_text(license_code, encoding="ascii")
        except OSError as exc:
            messagebox.showerror("Licenza non salvata", str(exc), parent=self.root)
            return

        self.status.set(f"Licenza salvata: {output_path}")
        messagebox.showinfo(
            "Licenza salvata",
            f"Codice alfanumerico salvato in:\n{output_path}",
            parent=self.root,
        )


def main() -> None:
    parser = argparse.ArgumentParser(description="Genera licenze per Frequenze Digitali")
    parser.add_argument("--hwid", default="", help="ID del dispositivo da licenziare")
    args = parser.parse_args()

    root = tk.Tk()
    KeyDigitaleApp(root, args.hwid)
    root.mainloop()


if __name__ == "__main__":
    main()
