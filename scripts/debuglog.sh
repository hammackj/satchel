#!/bin/bash
# Prints what Satchel saved about errors and the client API (written on /reload or logout).
SV="${WOW_SV:-/mnt/Games/CrossOver/World_of_Warcraft/drive_c/Program Files (x86)/World of Warcraft/_forever_/WTF/Account/HAMMACKJ/SavedVariables/Satchel.lua}"
[ -f "$SV" ] || { echo "No saved variables yet: $SV (log in with Satchel enabled, then /reload)"; exit 1; }
ls -l "$SV"
cat "$SV"
