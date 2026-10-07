#!/usr/bin/env python3
"""
First-run setup for the Crimson Steam Pirates Flatpak.

Shows a small GTK window that asks the user to locate their .ipa, offers the
optional HD art pack (downloaded from the Internet Archive, or a local
crimson.tar.gz), runs the conversion pipeline with a progress log, and
launches the game when done.

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
HD_PACK_URL = "https://archive.org/download/crimson.tar/crimson.tar.gz"

# HD art pack choices
HD_DOWNLOAD = "download"   # let the converter fetch crimson.tar.gz
HD_OFF = "off"             # original iPhone-resolution build
# anything else is the path to a local crimson.tar.gz


def conversion_command(ipa_path, hd=HD_OFF):
    cmd = [sys.executable, str(CONVERTER),
           "--ipa", str(ipa_path), "--out", str(GAME_DIR)]
    if hd == HD_DOWNLOAD:
        cmd.append("--download-hd-pack")
    elif hd != HD_OFF:
        cmd += ["--hd-pack", str(hd)]
    return cmd


def run_conversion(ipa_path, log, hd=HD_OFF):
    """Run convert.py, streaming its output to `log(line)`. Returns success."""
    GAME_DIR.parent.mkdir(parents=True, exist_ok=True)
    cmd = conversion_command(ipa_path, hd)
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
    win.set_default_size(640, 560)
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

    hd_check = Gtk.CheckButton(
        label="HD graphics (full-resolution art from the Chrome Web Store "
              "release)")
    hd_check.set_active(True)
    box.pack_start(hd_check, False, False, 0)

    hd_hint = Gtk.Label()
    hd_hint.set_line_wrap(True)
    hd_hint.set_xalign(0)
    hd_hint.set_markup(
        "<small>The HD art pack (~100 MB) is downloaded from the Internet "
        f"Archive:\n<tt>{HD_PACK_URL}</tt>\n"
        "Already have <tt>crimson.tar.gz</tt>? Choose it here to skip the "
        "download.</small>"
    )
    box.pack_start(hd_hint, False, False, 0)

    hd_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
    hd_entry = Gtk.Entry()
    hd_entry.set_placeholder_text("optional: path to crimson.tar.gz")
    hd_entry.set_hexpand(True)
    hd_browse = Gtk.Button(label="Browse…")
    hd_row.pack_start(hd_entry, True, True, 0)
    hd_row.pack_start(hd_browse, False, False, 0)
    box.pack_start(hd_row, False, False, 0)

    def on_hd_toggled(_chk):
        on = hd_check.get_active()
        hd_hint.set_sensitive(on)
        hd_row.set_sensitive(on)

    hd_check.connect("toggled", on_hd_toggled)

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

    def on_hd_browse(_btn):
        dlg = Gtk.FileChooserDialog(
            title="Select the HD art pack (crimson.tar.gz)",
            parent=win, action=Gtk.FileChooserAction.OPEN)
        dlg.add_buttons(Gtk.STOCK_CANCEL, Gtk.ResponseType.CANCEL,
                        Gtk.STOCK_OPEN, Gtk.ResponseType.OK)
        flt = Gtk.FileFilter()
        flt.set_name("HD art pack (*.tar.gz)")
        flt.add_pattern("*.tar.gz")
        dlg.add_filter(flt)
        if dlg.run() == Gtk.ResponseType.OK:
            hd_entry.set_text(dlg.get_filename())
        dlg.destroy()

    def set_inputs_sensitive(on):
        for w in (convert_btn, browse, hd_check):
            w.set_sensitive(on)
        hd_row.set_sensitive(on and hd_check.get_active())

    def on_convert(_btn):
        ipa = path_entry.get_text().strip()
        if not ipa or not Path(ipa).is_file():
            append_log("Please choose a valid .ipa file first.\n")
            return
        hd = HD_OFF
        if hd_check.get_active():
            hd = hd_entry.get_text().strip() or HD_DOWNLOAD
            if hd != HD_DOWNLOAD and not Path(hd).is_file():
                append_log("HD art pack not found: " + hd + "\n"
                           "Clear the field to download it instead.\n")
                return
        set_inputs_sensitive(False)

        def worker():
            ok = run_conversion(ipa, append_log, hd)
            if ok:
                append_log("\nSetup complete — launching game…\n")
                GLib.idle_add(launch_game)
            else:
                append_log("\nSetup failed. See the log above. If the IPA was "
                           "not recognised, make sure you downloaded the exact "
                           "build linked in the instructions. If the HD art "
                           "pack could not be downloaded, untick HD graphics "
                           "or choose a local crimson.tar.gz.\n")
                GLib.idle_add(lambda: set_inputs_sensitive(True))

        threading.Thread(target=worker, daemon=True).start()

    browse.connect("clicked", on_browse)
    hd_browse.connect("clicked", on_hd_browse)
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
    print("HD graphics use the Chrome Web Store release's art pack "
          f"(~100 MB): {HD_PACK_URL}")
    ans = input("HD art pack — [Enter] to download it, a path to "
                "crimson.tar.gz, or 'n' for iPhone resolution: ").strip()
    if ans.lower() in ("n", "no"):
        hd = HD_OFF
    elif not ans:
        hd = HD_DOWNLOAD
    elif Path(ans).expanduser().is_file():
        hd = str(Path(ans).expanduser())
    else:
        print("Not a file:", ans)
        return 1
    ok = run_conversion(ipa, lambda s: sys.stdout.write(s), hd)
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
