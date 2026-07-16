#!/usr/bin/env python3
"""
Apple PVRTC (.pvr / .pv1) → PNG decoder.

The 2011 Crimson Steam Pirates iPhone IPA ships many textures in PowerVR's
PVRTC compressed format, which is a PowerVR-hardware-only format that desktop
OpenGL cannot sample. We decode them on the CPU to RGBA and re-emit as PNG so
the Linux port can display them.

Format: classic "PVRTexTool v2" header (52 bytes, 13 little-endian uint32).

This module is pure original work — it reads the user's own texture data and
produces PNGs on the user's own machine. No copyrighted asset is bundled.
"""

import struct
from pathlib import Path

import texture2ddecoder
from PIL import Image

PVR_MAGIC = 0x21525650  # 'PVR!' little-endian

# pixel-format codes in the low byte of flags
FMT_PVRTC2 = 0x18  # 2 bits per pixel
FMT_PVRTC4 = 0x19  # 4 bits per pixel


class PVRError(Exception):
    pass


def parse_pvr_header(data: bytes):
    if len(data) < 52:
        raise PVRError("file too small for a PVR v2 header")
    fields = struct.unpack_from("<13I", data, 0)
    if fields[0] != 52:
        raise PVRError(f"unexpected header size {fields[0]} (want 52)")
    if fields[11] != PVR_MAGIC:
        raise PVRError("missing 'PVR!' magic — not a PVRTexTool v2 file")
    return {
        "height": fields[1],
        "width": fields[2],
        "mip_count": fields[3],
        "pixel_format": fields[4] & 0xFF,
        "has_alpha": bool(fields[4] & 0x8000),
        "data_size": fields[5],
        "bpp": fields[6],
        "header_size": fields[0],
        "num_surfaces": fields[12],
    }


def decode_pvrtc_to_rgba(data: bytes, header: dict) -> bytes:
    """Return raw RGBA bytes for the level-0 mip.

    texture2ddecoder.decode_pvrtc(data, w, h, do2bit) returns BGRA;
    we swap to RGBA.
    """
    do_2bit = header["bpp"] == 2
    payload = data[header["header_size"]:]
    expected = header["bpp"] * header["width"] * header["height"] // 8
    bgra = texture2ddecoder.decode_pvrtc(
        payload[:expected], header["width"], header["height"], do_2bit
    )
    arr = bytearray(bgra)
    for i in range(0, len(arr), 4):
        arr[i], arr[i + 2] = arr[i + 2], arr[i]
    return bytes(arr)


def decode_pvr_file(in_path, out_path):
    """Decode one .pvr/.pv1 file to a PNG at out_path. Raises PVRError on
    unsupported formats."""
    in_path = Path(in_path)
    out_path = Path(out_path)
    data = in_path.read_bytes()
    header = parse_pvr_header(data)
    if header["pixel_format"] not in (FMT_PVRTC2, FMT_PVRTC4):
        raise PVRError(
            f"unsupported pixel format 0x{header['pixel_format']:02x}"
        )
    rgba = decode_pvrtc_to_rgba(data, header)
    img = Image.frombytes("RGBA", (header["width"], header["height"]), rgba)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    img.save(out_path, "PNG", optimize=False)
    return header


if __name__ == "__main__":
    import sys
    if len(sys.argv) != 3:
        print("usage: pvr_decode.py <in.pvr> <out.png>", file=sys.stderr)
        sys.exit(1)
    h = decode_pvr_file(sys.argv[1], sys.argv[2])
    print(f"OK {h['width']}x{h['height']} bpp={h['bpp']} alpha={h['has_alpha']}")
