# dmgbuild settings used by scripts/make-dmg.sh. Geometry must match scripts/make-dmg-background.swift.
import os.path

app = defines["app"]  # noqa: F821
background = defines["background"]  # noqa: F821

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents/Resources/AppIcon.icns")

# Taller than the 436pt background to fit the title bar and the tab bar Finder may show.
window_rect = ((200, 120), (640, 468))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

icon_size = 112
text_size = 13
arrange_by = None
icon_locations = {
    os.path.basename(app): (170, 170),
    "Applications": (470, 170),
}
