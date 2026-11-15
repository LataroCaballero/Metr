# dmgbuild settings for the Metr release image (UI-SPEC "DMG Window Contract", D-12 look, D-21 tool).
# Run by scripts/release/make-dmg.sh as:
#   dmgbuild -s scripts/release/dmg-settings.py -D app=<Metr.app> -D background=<tiff> -D volicon=<icns> Metr <out.dmg>
# Icon positions are icon centers, as dmgbuild's icon_locations takes them.
import os.path

app = defines["app"]  # noqa: F821  (injected by dmgbuild)
background = defines["background"]  # noqa: F821
volicon = defines["volicon"]  # noqa: F821

format = "UDZO"
filesystem = "HFS+"

files = [app]
symlinks = {"Applications": "/Applications"}
icon = volicon
background = background

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"

window_rect = ((200, 200), (600, 400))
icon_size = 128
text_size = 12

icon_locations = {
    os.path.basename(app): (168, 180),
    "Applications": (432, 180),
}
