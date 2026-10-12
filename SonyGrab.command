#!/bin/bash
# Double-click this to open SonyGrab in your browser.
cd "$(dirname "$0")" || exit 1
exec python3 server.py
