# Installation cheat-sheet

**Full instructions:** see [README.md](README.md).

## TL;DR (Debian/Ubuntu)

```bash
# 1. deps
sudo apt install python3 python3-pip default-jre ffmpeg patch \
     build-essential cmake git libsdl2-dev freeglut3-dev \
     libgl1-mesa-dev libglu1-mesa-dev libx11-dev libxext-dev \
     libxrandr-dev libxxf86vm-dev libxcursor-dev libxinerama-dev zlib1g-dev libfreetype-dev libpng-dev
python3 -m venv ~/.venvs/csp   # PEP 668: system Python is externally managed
~/.venvs/csp/bin/pip install texture2ddecoder pillow
source ~/.venvs/csp/bin/activate

# 2. engine (one time)
scripts/build-moai.sh

# 3. get the IPA from the Internet Archive (see README), then:
#    (--download-hd-pack also fetches the HD art pack, ~100 MB; omit it for
#    the original iPhone-resolution game)
python3 converter/convert.py --ipa ~/Downloads/CrimsonSteam.ipa \
    --download-hd-pack \
    --out ~/.local/share/crimson-steam-pirates

# 4. play
cp build/moai ~/.local/share/crimson-steam-pirates/
cd ~/.local/share/crimson-steam-pirates && ./run.sh
```

Or install the Flatpak from `packaging/flatpak/` for a first-run setup screen.
