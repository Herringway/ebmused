import core.stdc.stdio;
import core.stdc.stdlib;
import core.stdc.string;
import core.stdc.errno;
import core.sys.windows.windows : GetFullPathNameA, MAX_PATH, MB_ICONERROR, MB_ICONEXCLAMATION;
import std.string;
import std.stdio;
import ebmusv2;
import misc;
import loadrom;
import ranges;
import win32.misc;

__gshared string[] bgm_title;
__gshared bool metadata_changed;
__gshared private char[MAX_PATH+8] md_filename;
__gshared File orig_rom;
__gshared string orig_rom_filename;
__gshared int orig_rom_offset;

immutable bgm_orig_title = [
	"Gas Station",
	"Your Name, Please",
	"Choose a File",
	"None",
	"Fanfare - You Won!",
	"Level Up",
	"A Bad Dream",
	"Battle Swirl (Boss)",
	"Battle Swirl (Ambushed)",
	"(Unused)",
	"Fanfare - You've Got A New Friend!",
	"Fanfare - Instant Revitalization",
	"Teleportation - Departure",
	"Teleportation - Failure",
	"Falling Underground",
	"Doctor Andonuts' Lab",
	"Suspicious House",
	"Sloppy House",
	"Friendly Neighbors",
	"Arcade",
	"Pokey's House",
	"Hospital",
	"Home Sweet Home",
	"Paula's Theme",
	"Chaos Theater",
	"Enjoy Your Stay",
	"Good Morning, Eagleland",
	"Department Store",
	"Onett at Night (Version 1)",
	"Welcome to Your Sanctuary",
	"A Flash of Memory",
	"Melody - Giant Step", //These are the melodies as Ness hears them
	"Melody - Lilliput Steps",
	"Melody - Milky Well",
	"Melody - Rainy Circle",
	"Melody - Magnet Hill",
	"Melody - Pink Cloud",
	"Melody - Lumine Hall",
	"Melody - Fire Spring",
	"Third Strongest", //aka "Approaching Mt. Itoi" in MOTHER 1
	"Alien Investigation (Stonehenge Base)",
	"Fire Spring",
	"Belch's Factory",
	"Threed, Zombie Central",
	"Spooky Cave",
	"Onett (first pattern is skipped in-game)",
	"The Metropolis of Fourside",
	"Saturn Valley",
	"Monkey Caves",
	"Moonside Swing",
	"Dusty Dunes Desert",
	"Peaceful Rest Valley",
	"Happy Happy Village",
	"Winters White",
	"Caverns of Winters",
	"Summers, Eternal Tourist Trap",
	"Jackie's Cafe",
	"Sailing to Scaraba - Departure",
	"The Floating Kingdom of Dalaam",
	"Mu Training",
	"Bazaar",
	"Scaraba Desert",
	"In the Pyramid",
	"Deep Darkness",
	"Tenda Village",
	"Magicant - Welcome Home",
	"Magicant - Dark Thoughts",
	"Lost Underworld",
	"The Cliff That Time Forgot", //Cave of the Beatles
	"The Past", //Cave of the Beach Boys
	"Giygas' Lair", //Intestines
	"Giygas Awakens",
	"Giygas - Struggling (Phase 2)",
	"Giygas - Weakening",
	"Giygas - Breaking Down",
	"Runaway Five, Live at the Chaos Theater",
	"Runaway Five, On Tour",
	"Runaway Five, Live at the Topolla Theater",
	"Magicant - The Power",
	"Venus' Performance",
	"Yellow Submarine",
	"Bicycle",
	"Sky Runner - In Flight",
	"Sky Runner - Going Down",
	"Bulldozer",
	"Tessie",
	"Greyhand Bus",
	"What a Great Photograph!",
	"Escargo Express at your Service!",
	"The Heroes Return (Part 1)",
	"Phase Distorter - Time Vortex",
	"Coffee Break", //aka You've Come Far, Ness
	"Because I Love You",
	"Good Friends, Bad Friends",
	"Smiles and Tears",
	"Battle Against a Weird Opponent",
	"Battle Against a Machine",
	"Battle Against a Mobile Opponent",
	"Battle Against Belch",
	"Battle Against a New Age Retro Hippie",
	"Battle Against a Weak Opponent",
	"Battle Against an Unsettling Opponent",
	"Sanctuary Guardian",
	"Kraken of the Sea",
	"Giygas - Cease to Exist!", //aka Pokey Means Business
	"Inside the Dungeon",
	"Megaton Walk",
	"Magicant - The Sea of Eden",
	"Sky Runner - Explosion (Unused)",
	"Sky Runner - Explosion",
	"Magic Cake",
	"Pokey's House (with Buzz Buzz)",
	"Buzz Buzz Swatted",
	"Onett at Night (Version 2, with Buzz Buzz)",
	"Phone Call",
	"Annoying Knock (Right)",
	"Pink Cloud Shrine",
	"Buzz Buzz Emerges",
	"Buzz Buzz's Prophecy",
	"Heartless Hotel",
	"Onett Flyover",
	"Onett (with sunrise)",
	"Fanfare - A Good Buddy",
	"Starman Junior Appears",
	"Snow Wood Boarding School", //aka Snowman
	"Phase Distorter - Failure",
	"Phase Distorter - Teleport to Lost Underworld",
	"Boy Meets Girl (Twoson)",
	"Threed, Free At Last",
	"The Runaway Five, Free To Go!",
	"Flying Man",
	"Cave Ambiance (\"Onett at Night Version 2\")",
	"Deep Underground (Unused)", //Extra-spooky MOTHER 1 track
	"Greeting the Sanctuary Boss",
	"Teleportation - Arrival",
	"Saturn Valley Caverns",
	"Elevator (Going Down)",
	"Elevator (Going Up)",
	"Elevator (Stopping)",
	"Topolla Theater",
	"Battle Aganst Belch (Duplicate Entry)",
	"Magicant - Realization",
	"Magicant - Departure",
	"Sailing to Scaraba - Onwards!",
	"Stonehenge Base Shuts Down",
	"Tessie Watchers",
	"Meteor Fall",
	"Battle Against an Otherworldly Foe",
	"The Runaway Five To The Rescue!",
	"Annoying Knock (Left)",
	"Alien Investigation (Onett)",
	"Past Your Bedtime",
	"Pokey's Theme",
	"Onett at Night (Version 4, with Buzz Buzz)",
	"Greeting the Sanctuary Boss (Duplicate Entry)",
	"Meteor Strike (fades into 0x98)",
	"Opening Credits",
	"Are You Sure? Yep!",
	"Peaceful Rest Valley Ambiance",
	"Sound Stone - Giant Step",
	"Sound Stone - Lilliput Steps",
	"Sound Stone - Milky Well",
	"Sound Stone - Rainy Circle",
	"Sound Stone - Magnet Hill",
	"Sound Stone - Pink Cloud",
	"Sound Stone - Lumine Hall",
	"Sound Stone - Fire Spring",
	"Sound Stone - Empty",
	"Eight Melodies",
	"Dalaam Flyover",
	"Winters Flyover",
	"Pokey's Theme (Helicopter)",
	"Good Morning, Moonside",
	"Gas Station (Part 2)",
	"Title Screen",
	"Battle Swirl (Normal)",
	"Pokey Springs Into Action",
	"Good Morning, Scaraba",
	"Robotomy",
	"Pokey's Helicopter (Unused)",
	"The Heroes Return (Part 2)",
	"Static",
	"Fanfare - Instant Victory",
	"You Win! (Version 3, versus Boss)",
	"Giygas - Lashing Out (Phase 3)",
	"Giygas - Mindless (Phase 1)",
	"Giygas - Give Us Strength!",
	"Good Morning, Winters",
	"Sound Stone - Empty (Duplicate Entry)",
	"Giygas - Breaking Down (Quiet)",
	"Giygas - Weakening (Quiet)",
];

void open_orig_rom(string filename) {
	File f = File(filename, "rb");
	long size = f.size;
	if (size != rom_size) {
		throw new EbmusedWarningException("File is not same size as current ROM", filename.fromStringz.idup);
	}
	if (orig_rom.isOpen) orig_rom.close();
	orig_rom = f;
	orig_rom_offset = size & 0x200;
	orig_rom_filename = filename;
}

void load_metadata() nothrow {
	bgm_title.length = bgm_orig_title.length;
	for (int i = 0; i < NUM_SONGS; i++) {
		bgm_title[i] = bgm_orig_title[i];
	}
	metadata_changed = false;

	// We want an absolute path here, so we don't get screwed by
	// GetOpenFileName's current-directory shenanigans when we update.
	char *lastpart;
	GetFullPathNameA(rom_filename.toStringz, MAX_PATH, &md_filename[0], &lastpart);
	char *ext = strrchr(lastpart, '.');
	if (!ext) ext = lastpart + strlen(lastpart);
	strcpy(ext, ".ebmused");

	FILE *mf = fopen(&md_filename[0], "r");
	if (!mf) return;

	int c;
	while ((c = fgetc(mf)) >= 0) {
		char[MAX_PATH] buf;
static assert(MAX_TITLE_LEN < MAX_PATH);
		if (c == 'O') {
			fgetc(mf);
			fgets(&buf[0], MAX_PATH, mf);
			{ char *p = strchr(&buf[0], '\n'); if (p) *p = '\0'; }
			try {
				open_orig_rom(buf.fromStringz.idup);
			} catch (Exception e) {
				MessageBox2(e.msg, "Unable to load rom", MB_ICONERROR);
			}
		} else if (c == 'R') {
			int start, end;
			fscanf(mf, "%X %X", cast(uint*)&start, cast(uint*)&end);
			change_range(start, end, AREA_NON_SPC, AREA_FREE);
			while ((c = fgetc(mf)) >= 0 && c != '\n') {}
		} else if (c == 'T') {
			uint bgm;
			fscanf(mf, "%X %"~MAX_TITLE_LEN_STR~"[^\n]", &bgm, &buf[0]);
			if (--bgm < NUM_SONGS)
				bgm_title[bgm] = buf.fromStringz.idup;
			while ((c = fgetc(mf)) >= 0 && c != '\n') {}
		} else {
			printf("unrecognized metadata line %c\n", c);
		}
	}
	fclose(mf);
}

void save_metadata() {
	import std.file : remove;
	if (!metadata_changed) return;
	const filename = md_filename.fromStringz;
	File mf = File(filename, "w");
	scope(exit) {
		auto size = mf.tell;
		mf.close();
		if (size == 0) {
			remove(filename);
		}
	}

	if (orig_rom_filename) {
		mf.writefln!"O %s"(orig_rom_filename);
	}

	// SPC ranges containing at least one free area
	for (int i = 0; i < area_count; i++) {
		int start = areas[i].address;
		int has_free = 0;
		for (; areas[i].pack >= AREA_FREE; i++) {
			has_free |= areas[i].pack == AREA_FREE;
		}
		if (has_free) {
			mf.writefln!"R %06X %06X"(start, areas[i].address);
		}
	}

	for (int i = 0; i < NUM_SONGS; i++) {
		if (bgm_title[i] != bgm_orig_title[i]) {
			mf.writefln!"T %02X %s"(i+1, bgm_title[i].fromStringz);
		}
	}

	metadata_changed = false;
}

void free_metadata() nothrow {
	if (orig_rom.isOpen) { try { orig_rom.close(); } catch (Exception) {} }
}
