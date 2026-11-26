# Switches only tests set; a real game never does. They live in a script of their own with no other script behind
# it: a static variable on net/local_room.gd left that script, and every script it loads, in use when the engine
# exits, which the export tool reads as an error.
extends RefCounted

## WH1d: the next solo run's Ward has the homes, as if the game was started with `ward_homes=1`.
static var ward_homes := false
