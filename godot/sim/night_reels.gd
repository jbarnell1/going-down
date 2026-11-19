# Friday's three nightly reels, timed in host seconds.
extends RefCounted

const SHOTS := [
	[
		[3.5, "BEDTIME FACT 1", "Well done today! Here is a bedtime fact."],
		[3.0, "THE SOKE", "Before Lidgate, there was a district here."],
		[3.5, "", "A hospital. Offices. Somewhere for children."],
		[3.5, "", "It began to sink. Then it began to misbehave."],
		[4.5, "THE LID", "So we put a lid on it, and built somewhere nicer on the lid."],
		[3.0, "YOU ARE HERE", "You live just under the lid. Lucky you!"],
		[3.0, "", "Sleep well. Nothing is below Lidgate."],
		[3.0, "", "CREW 7. DAY 1. FOUR WENT DOWN. FOUR CAME UP."],
	],
	[
		[3.0, "BEDTIME FACT 2", "Good evening! Another bedtime fact."],
		[4.0, "CREW 41", "You are not our first crew. We have sent a great many."],
		[3.5, "", "Some chose to stay below. We respect that."],
		[4.0, "", "They did not get on. A quota can do that to friends."],
		[5.0, "HELP YOURSELF", "Their pay is still down there, in the drawers. Do help yourselves."],
		[2.5, "", "Share nicely. Sleep well!"],
		[3.0, "", "CREW 7. DAY 9. FOUR WENT DOWN. ONE IS BELOW, WITH ALL FOUR TAPES. IT IS RECORDING."],
	],
	[
		[3.0, "BEDTIME FACT 3", "Good evening! Tonight: punctuality."],
		[4.0, "NIGHT STAFF", "Miss the car, and our night staff will fetch you."],
		[3.0, "WITHIN THE HOUR", "They are very quick. They have to be."],
		[5.0, "", "A floor likes to keep people busy. Stay too long, and it finds you a job."],
		[4.0, "", "You would not enjoy the job. You would do it forever."],
		[2.5, "BE ABOARD", "So do be on time. Sleep well!"],
		[3.0, "", "CREW 7. THE ONE BELOW HAS A NEW UNIFORM. IT KEPT ITS FACE."],
	],
]

static func duration(day: int) -> float:
	if day < 1 or day > SHOTS.size():
		return 0.0
	var seconds := 0.0
	for shot: Array in SHOTS[day - 1]:
		seconds += float(shot[0])
	return seconds
