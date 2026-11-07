# dmgbuild settings for the Slip installer window.
# Usage: dmgbuild -s Resources/dmg/settings.py -D app=path/to/Slip.app "Slip" Slip.dmg
# The background is rendered by scripts/make-dmg-background.swift; keep icon positions in
# sync with the glows and arrow drawn there.
import os.path

here = os.path.dirname(os.path.abspath(globals().get("__file__", "Resources/dmg/settings.py")))
app = defines.get("app", "build/mac-release/notarized/Slip.app")  # noqa: F821 (provided by dmgbuild)
app_name = os.path.basename(app)

# Contents
files = [app]
symlinks = {"Applications": "/Applications"}
hide_extensions = [app_name]

# Image
format = "ULFO"  # LZFSE: smaller and faster than zlib; macOS 10.11+
filesystem = "HFS+"
size = None
icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")  # volume icon

# Window
background = os.path.join(here, "background.tiff")
# Finder's window bounds include the title bar, so add its height to the 400 pt content.
window_rect = ((200, 140), (640, 432))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False

# Icon view
icon_size = 128
text_size = 13
label_pos = "bottom"
arrange_by = None
icon_locations = {
    app_name: (160, 186),
    "Applications": (480, 186),
}
