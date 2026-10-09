# dmgbuild settings for build/ReSkate.dmg (used by build.sh).
# Background is 660x400 pt; icon centers must match Icon/make_dmg_background.swift.
app = defines["app"]

files = [app]
symlinks = {"Applications": "/Applications"}
format = "UDZO"
background = defines["background"]

window_rect = ((200, 160), (660, 432))  # + title bar, so all 400 pt of background show
default_view = "icon-view"
show_status_bar = show_tab_view = show_toolbar = show_pathbar = show_sidebar = False
icon_size = 112
text_size = 13
icon_locations = {"ReSkate.app": (180, 215), "Applications": (480, 215)}
hide_extensions = ["ReSkate.app"]
