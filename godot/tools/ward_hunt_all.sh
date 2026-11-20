#!/bin/sh
# WD1: tools/ward_hunt.gd in parallel, one process per skill and crew pair (six). Usage:
#   sh tools/ward_hunt_all.sh <out-prefix> [args...]      e.g. sh tools/ward_hunt_all.sh /tmp/now seeds=200
# Prints the table rows of all six when they are done.
GODOT=${GODOT:-C:/new_game/tools/godot/Godot_v4.7.2-stable_win64_console.exe}
out=$1
shift
cd "$(dirname "$0")/.." || exit 1
for skill in careless sensible expert; do
	for crews in 1,2 4,6; do
		"$GODOT" --headless --path . --script res://tools/ward_hunt.gd -- skills=$skill crews=$crews "$@" > "$out.$skill.$crews.log" 2>&1 &
	done
done
wait
for skill in careless sensible expert; do
	for crews in 1,2 4,6; do
		grep '^| [0-9]' "$out.$skill.$crews.log"
	done
done
