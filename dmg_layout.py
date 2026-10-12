#!/usr/bin/env python3
"""Writes dmg.DS_Store, the Finder layout of the disk image SonyGrab ships in.

Icon view, two big icons side by side: the app on the left, Applications on
the right. No background picture, so the window follows light and dark mode
like any other Finder window.

release.sh copies dmg.DS_Store into the image as it is. This script only needs
running again to change the layout, and needs one package to do it:

    python3 -m pip install ds_store
    python3 dmg_layout.py
"""
from ds_store import DSStore

WIDTH, HEIGHT = 560, 360

with DSStore.open("dmg.DS_Store", "w+") as d:
    d["."]["vSrn"] = ("long", 1)
    d["."]["bwsp"] = {
        "ShowStatusBar": False, "ShowToolbar": False, "ShowTabView": False,
        "ShowPathbar": False, "ShowSidebar": False, "ContainerShowSidebar": False,
        "PreviewPaneVisibility": False, "SidebarWidth": 0,
        "WindowBounds": "{{300, 200}, {%d, %d}}" % (WIDTH, HEIGHT),
    }
    d["."]["icvp"] = {
        "viewOptionsVersion": 1, "backgroundType": 0,
        "backgroundColorRed": 1.0, "backgroundColorGreen": 1.0, "backgroundColorBlue": 1.0,
        "gridOffsetX": 0.0, "gridOffsetY": 0.0, "gridSpacing": 100.0, "arrangeBy": "none",
        "showIconPreview": True, "showItemInfo": False, "labelOnBottom": True,
        "textSize": 13.0, "iconSize": 128.0, "scrollPositionX": 0.0, "scrollPositionY": 0.0,
    }
    d["."]["icvl"] = ("type", b"icnv")
    # Names as they appear in the image. release.sh must use the same two.
    d["SonyGrab.app"]["Iloc"] = (150, 160)
    d["Applications"]["Iloc"] = (410, 160)
