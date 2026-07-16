#!/usr/bin/env python3
"""
First-run setup for the Crimson Steam Pirates Flatpak.

Shows a small GTK window that asks the user to locate their .ipa, runs the
conversion pipeline with a progress log, and launches the game when done.

Falls back to a plain terminal flow if GTK isn't available.
"""
import os
import subprocess
import sys
import threading
from pathlib import Path

CSP_LIB = Path(os.environ.get("CSP_LIB", "/app/lib/csp"))
DATA_DIR = Path(os.environ.get("DATA_DIR",
                Path.home() / ".local/share/crimson-steam-pirates"))
GAME_DIR = Path(os.environ.get("GAME_DIR", DATA_DIR / "game"))
CONVERTER = CSP_LIB / "converter" / "convert.py"
MOAI = CSP_LIB / "moai"

ARCHIVE_URL = "https://archive.org/download/toasterifc-ipa-collection/Crimson%20Steam%20Pirates-v1.2.ipa"


def run_conversion(ipa_path, log):
    """Run convert.py, streaming its output to `log(line)`. Returns success."""
    GAME_DIR.parent.mkdir(parents=True, exist_ok=True)
    cmd = [sys.executable, str(CONVERTER),
           "--ipa", str(ipa_path), "--out", str(GAME_DIR)]
    log(f"$ {' '.join(cmd)}\n")
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True)
    for line in proc.stdout:
        log(line)
    proc.wait()
    return proc.returncode == 0


def launch_game():
    os.chdir(GAME_DIR)
    os.execv(str(MOAI), [str(MOAI), "boot.lua"])


# ---------------------------------------------------------------------------
# GTK path
# ---------------------------------------------------------------------------
def gui_main():
    import gi
    gi.require_version("Gtk", "3.0")
    from gi.repository import Gtk, GLib

    win = Gtk.Window(title="Crimson Steam Pirates — Setup")
    win.set_default_size(640, 480)
    win.set_border_width(16)
    win.connect("destroy", Gtk.main_quit)

    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
    win.add(box)

    intro = Gtk.Label()
    intro.set_line_wrap(True)
    intro.set_xalign(0)
    intro.set_markup(
        "<b>One-time setup</b>\n\n"
        "This will rebuild Crimson Steam Pirates from your own copy of the "
        "original iPhone app (<tt>.ipa</tt>). No game data is included with "
        "this app — you supply it.\n\n"
        f"You can download the original from the Internet Archive:\n"
        f"<tt>{ARCHIVE_URL}</tt>\n\n"
        "Then choose the <tt>.ipa</tt> file below."
    )
    box.pack_start(intro, False, False, 0)

    chooser_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
    path_entry = Gtk.Entry()
    path_entry.set_placeholder_text("path to CrimsonSteam.ipa")
    path_entry.set_hexpand(True)
    browse = Gtk.Button(label="Browse…")
    chooser_row.pack_start(path_entry, True, True, 0)
    chooser_row.pack_start(browse, False, False, 0)
    box.pack_start(chooser_row, False, False, 0)

    convert_btn = Gtk.Button(label="Convert and play")
    box.pack_start(convert_btn, False, False, 0)

    scroll = Gtk.ScrolledWindow()
    scroll.set_vexpand(True)
    logview = Gtk.TextView()
    logview.set_editable(False)
    logview.set_monospace(True)
    scroll.add(logview)
    box.pack_start(scroll, True, True, 0)
    logbuf = logview.get_buffer()

    def append_log(text):
        def _do():
            logbuf.insert(logbuf.get_end_iter(), text)
            mark = logbuf.create_mark(None, logbuf.get_end_iter(), False)
            logview.scroll_to_mark(mark, 0.0, False, 0, 0)
        GLib.idle_add(_do)

    def on_browse(_btn):
        dlg = Gtk.FileChooserDialog(
            title="Select the Crimson Steam Pirates IPA",
            parent=win, action=Gtk.FileChooserAction.OPEN)
        dlg.add_buttons(Gtk.STOCK_CANCEL, Gtk.ResponseType.CANCEL,
                        Gtk.STOCK_OPEN, Gtk.ResponseType.OK)
        flt = Gtk.FileFilter()
        flt.set_name("iOS app archive (*.ipa)")
        flt.add_pattern("*.ipa")
        dlg.add_filter(flt)
        if dlg.run() == Gtk.ResponseType.OK:
            path_entry.set_text(dlg.get_filename())
        dlg.destroy()

    def on_convert(_btn):
        ipa = path_entry.get_text().strip()
        if not ipa or not Path(ipa).is_file():
            append_log("Please choose a valid .ipa file first.\n")
            return
        convert_btn.set_sensitive(False)
        browse.set_sensitive(False)

        def worker():
            ok = run_conversion(ipa, append_log)
            if ok:
                append_log("\nSetup complete — launching game…\n")
                GLib.idle_add(launch_game)
            else:
                append_log("\nSetup failed. See the log above. If the IPA was "
                           "not recognised, make sure you downloaded the exact "
                           "build linked in the instructions.\n")
                GLib.idle_add(lambda: convert_btn.set_sensitive(True))
                GLib.idle_add(lambda: browse.set_sensitive(True))

        threading.Thread(target=worker, daemon=True).start()

    browse.connect("clicked", on_browse)
    convert_btn.connect("clicked", on_convert)

    win.show_all()
    Gtk.main()


# ---------------------------------------------------------------------------
# Terminal fallback
# ---------------------------------------------------------------------------
def cli_main():
    print("Crimson Steam Pirates — one-time setup")
    print(f"Download the original IPA from: {ARCHIVE_URL}")
    ipa = input("Path to your .ipa file: ").strip()
    if not Path(ipa).is_file():
        print("Not a file:", ipa)
        return 1
    ok = run_conversion(ipa, lambda s: sys.stdout.write(s))
    if ok:
        print("Launching…")
        launch_game()
    else:
        print("Setup failed — see log above.")
        return 1
    return 0


def main():
    try:
        import gi  # noqa: F401
        gui_main()
        return 0
    except Exception:
        return cli_main()


if __name__ == "__main__":
    sys.exit(main())
