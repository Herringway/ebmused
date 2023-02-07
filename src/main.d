
import core.stdc.stdio;
import core.stdc.string;
import core.stdc.errno;
import core.stdc.stdlib;
import core.sys.windows.windows;
import core.sys.windows.commdlg;
import core.sys.windows.commctrl;

import std.algorithm.comparison : max, min;
import std.exception;
import std.format;
import std.experimental.logger;
import std.stdio;
import std.string;
import std.utf;
import misc;
import structs;
import help;
import brr;
import play;
import song;
import win32.dialogs;
import win32.handles;
import win32.misc;
import win32.ui;


enum {
	MAIN_WINDOW_WIDTH = 720,
	MAIN_WINDOW_HEIGHT = 540,
	TAB_CONTROL_WIDTH = 600,
	TAB_CONTROL_HEIGHT = 25,
	CODELIST_WINDOW_WIDTH = 640,
	CODELIST_WINDOW_HEIGHT = 480
}

__gshared structs.song cur_song;
__gshared song_state pattop_state, state;
__gshared int octave = 2;
__gshared ptrdiff_t midiDevice = -1;




struct spcDetails {
	ushort music_table_addr;
	ushort instrument_table_addr;
	ushort music_addr;
	ubyte music_index;
}

bool try_parse_music_table(const(ubyte) *spc, spcDetails *out_details) {
	if (memcmp(&spc[0], "\x1C\x5D\xF5".ptr, 3) != 0) return false;
	ushort addr_hi = *(cast(ushort*)&spc[3]);

	// Check for Konami-only branch
	if (spc[5] == 0xF0) {
		spc += 2; // skip two bytes (beq ..)
	}

	if (spc[5] != 0xFD) return false;

	// Check for Starfox branch
	if (memcmp(&spc[6], "\xD0\x03\xC4".ptr, 3) == 0 && spc[10] == 0x6F) {
		spc += 5; // skip these 5 bytes
	}

	if (spc[6] != 0xF5) return false; // mov a,
	ushort addr_lo = *(cast(ushort*)&spc[7]); //       $....+x

	if (spc[9] != 0xDA || spc[10] != 0x40) return false; // mov $40,ya

	// Validate retrieved address
	if (addr_lo != addr_hi - 1) return false;

	out_details.music_table_addr = addr_lo;
	return true;
}

bool try_parse_music_address(const(ubyte)* spc, spcDetails *out_details) {
	ushort loop_addr = *cast(ushort *)&spc[0x40];
	ushort *terminator = cast(ushort *)&spc[loop_addr];
	while (terminator[0]) {
		// Make sure terminator stays in bounds and allows space for one pattern block after it.
		// Also arbitrarily limit number of patterns between loop and terminator to 256.
		if (cast(ubyte *)terminator < &spc[0x10000 - 16 - 2]
			&& terminator - cast(ushort *)&spc[loop_addr] <= 0x100
		) {
			terminator++;
		} else {
			return false;
		}
	}

	// Count all unique patterns past the terminator.
	ushort[8]* patterns = cast(ushort[8]*)&terminator[1];
	uint numPatterns = 0;
	const size_t maxPatterns = (&spc[0xFFFF] - cast(ubyte *)patterns) / (ushort[8]).sizeof; // Amount of patterns that can possibly fit.
	// Pattern is only valid if all channel addresses are ordered. (Ignore 0x0000 channel addresses)
	for (uint i = 0;
		i < maxPatterns // Limit count to as many as can possibly fit in memory
			&& (patterns[i][0] < patterns[i][1] || !patterns[i][1])
			&& (patterns[i][1] < patterns[i][2] || !patterns[i][2])
			&& (patterns[i][2] < patterns[i][3] || !patterns[i][3])
			&& (patterns[i][3] < patterns[i][4] || !patterns[i][4])
			&& (patterns[i][4] < patterns[i][5] || !patterns[i][5])
			&& (patterns[i][5] < patterns[i][6] || !patterns[i][6])
			&& (patterns[i][6] < patterns[i][7] || !patterns[i][7])
			;
		i++) {
		numPatterns = i + 1;
	}

	// sanity check. Assert smallest pattern is greater than 0xFF and number of patterns is less than as many as can fit in memory
	if (patterns[0][0] <= 0xFF || numPatterns == 0 || numPatterns >= maxPatterns) return false;

	// Find the first pattern by iterating backwards until one pattern doesn't point at a pattern address.
	ushort *music_addr_ptr = cast(ushort*)&spc[loop_addr];
	bool patternExists = true;
	for (WORD* prev = &music_addr_ptr[-1]; prev && patternExists; prev--) {
		patternExists = false;
		// if any patterns contain prev, continue
		for (uint i = 0; i < numPatterns; i++) {
			if (patterns[i] == *cast(ushort[8]*)(&spc[*prev])) {
				patternExists = true;
				music_addr_ptr = prev;
				break;
			}
		}
	}

	// sanity check
	if (cast(ubyte*)music_addr_ptr - spc <= 0xFF) return false;

	out_details.music_addr = cast(ushort)(cast(ubyte*)music_addr_ptr - spc);
	return true;
}

bool try_parse_inst_directory(const BYTE *spc, spcDetails *out_details) {
	if (memcmp(spc, "\xCF\xDA\x14\x60\x98".ptr, 5) == 0 && memcmp(&spc[6], "\x14\x98".ptr, 2) == 0 && spc[9] == 0x15) {
		out_details.instrument_table_addr = spc[5] | (spc[8] << 8);
		return true;
	}

	return false;
}

enum SPC_RESULTS {
	HAS_MUSIC = 1 << 0,
	HAS_MUSIC_TABLE = 1 << 1,
	HAS_INSTRUMENTS = 1 << 2
}
SPC_RESULTS try_parse_spc(const(ubyte)* spc, spcDetails *out_details) {
	bool foundMusic = false,
		foundMusicTable = false,
		foundInst = false;
	// For i in 0 .. 0xFF00, and also stop if all 3 things we're looking for have been found
	for (int i = 0; i < 0xFF00 && !(foundMusicTable && foundInst); i++) {
		if (!foundMusicTable && spc[i] == 0x1C)
			foundMusicTable = try_parse_music_table(&spc[i], out_details);
		else if (!foundInst && spc[i] == 0xCF)
			foundInst = try_parse_inst_directory(&spc[i], out_details);
	}

	foundMusic = try_parse_music_address(spc, out_details);

	// If we couldn't find the music via snooping the $40 address, try checking if we found a music table.
	if (!foundMusic && foundMusicTable) {
		// Try to get the bgm index from one of these locations, the first that isn't 0...
		ubyte bgm_index = spc[0x00] ? spc[0x00]
			: spc[0x04] ? spc[0x04]
			: spc[0x08] ? spc[0x08]
			: spc[0xF3] ? spc[0xF3]
			: spc[0xF4];
		if (bgm_index) {
			out_details.music_index = bgm_index;
			out_details.music_addr = (cast(ushort *)&spc[out_details.music_table_addr])[bgm_index];
			foundMusic = true;
		} else {
			// If we couldn't find the bgm index, try to guess it from the table using the pointer at 0x40
			ushort music_addr = *(cast(ushort*)(&spc[0x40]));
			ushort closestDiff = 0xFFFF;
			for (uint i = 0; i < 0xFF; i++) {
				ushort addr = (cast(ushort *)(&spc[out_details.music_table_addr]))[i];
				if (music_addr < addr && addr - music_addr < closestDiff) {
					closestDiff = cast(ushort)(addr - music_addr);
					bgm_index = cast(ubyte)i;
				}
			}

			if (music_addr > 0xFF) {
				out_details.music_addr = music_addr;
				out_details.music_index = 0;
				foundMusic = true;
			}
		}
	}

	SPC_RESULTS results = cast(SPC_RESULTS)0;
	if (foundMusicTable) results |= SPC_RESULTS.HAS_MUSIC_TABLE;
	if (foundMusic) results |= SPC_RESULTS.HAS_MUSIC;
	if (foundInst) results |= SPC_RESULTS.HAS_INSTRUMENTS;
	return results;
}
static void import_spc() {
	string file = openFilePrompt("SPC Savestates (*.spc)\0*.spc\0All Files\0*.*\0");
	if (!file) return;

	FILE *f = fopen(file.toStringz, "rb");
	if (!f) {
		MessageBox2(strerror(errno).fromStringz, "Import", MB_ICONEXCLAMATION);
		return;
	}

	// Backup the currently loaded SPC in case we need to restore it upon an error.
	// This can be updated once methods like decode_samples don't rely on the global "spc" variable.
	BYTE[0x10000] backup_spc = spc;
	WORD original_sample_ptr_base = sample_ptr_base;

	BYTE[0x80] dsp;

	if (fseek(f, 0x100, SEEK_SET) == 0
		&& fread(&spc[0], 0x10000, 1, f) == 1
		&& fread(&dsp[0], 0x80, 1, f) == 1
	) {
		sample_ptr_base = dsp[0x5D] << 8;
		decode_samples(&spc[sample_ptr_base]);

		spcDetails details;
		SPC_RESULTS results = try_parse_spc(&spc[0], &details);
		if (results) {
			if (results & SPC_RESULTS.HAS_INSTRUMENTS) {
				printf("Instrument table found: %#X\n", details.instrument_table_addr);
				inst_base = details.instrument_table_addr;
			}
			if (results & SPC_RESULTS.HAS_MUSIC) {
				printf("Music table found: %#X\n", details.music_table_addr);
				printf("Music index found: %#X\n", details.music_index);
				printf("Music found: %#X\n", details.music_addr);

				free_song(&cur_song);
				decompile_song(&cur_song, details.music_addr, 0xffff);
			}

			initialize_state();
			SendMessage(tab_hwnd[current_tab], WM_SONG_IMPORTED, 0, 0);
		} else {
			// Restore SPC state and samples
			spc = backup_spc;
			sample_ptr_base = original_sample_ptr_base;
			decode_samples(&spc[sample_ptr_base]);

			MessageBox2("Could not parse SPC.", "SPC Import", MB_ICONEXCLAMATION);
		}
	} else {
		// Restore SPC state
		spc = backup_spc;

		if (feof(f))
			MessageBox2("End-of-file reached while reading the SPC file", "Import", MB_ICONEXCLAMATION);
		else
			MessageBox2("Error reading the SPC file", "Import", MB_ICONEXCLAMATION);
	}

	fclose(f);
}
private T read(T)(const(ubyte)[] data, size_t offset = 0) {
	return (cast(const(T)[])(data[offset .. offset + T.sizeof]))[0];
}
private const(ubyte)[] loadAllSubpacks(scope ubyte[] buffer, const(ubyte)[] pack) @safe {
	ushort size, base;
	while (true) {
		if (pack.length == 0) {
			break;
		}
		size = read!ushort(pack);
		if (size == 0) {
			break;
		}
		base = read!ushort(pack, 2);
		if (size + base > 65535) {
			infof("Loading %s bytes to $%04X will overflow - truncating", size, base);
		}
		const truncated = min(65535, base + size) - base;
		buffer[base .. base + truncated] = pack[4 .. truncated + 4];
		pack = pack[size + 4 .. $];
	}
	return pack[2 .. $];
}
void import_nspc() {
	string file = openFilePrompt("NSPC File (*.nspc)\0*.nspc\0All Files\0*.*\0");
	if (!file) return;
	import nspcplay;
	import std.file : read;
	auto nspcFile = cast(ubyte[])read(file);
	ubyte[0x10000] backup_spc = spc;
	WORD original_sample_ptr_base = sample_ptr_base;

	const header = (cast(NSPCFileHeader[])(nspcFile[0 .. NSPCFileHeader.sizeof]))[0];
	loadAllSubpacks(spc[], nspcFile[NSPCFileHeader.sizeof .. $]);

	//samples
	sample_ptr_base = header.sampleBase;
	decode_samples(&spc[sample_ptr_base]);

	//instruments
	inst_base = header.instrumentBase;

	//song data
	free_song(&cur_song);
	decompile_song(&cur_song, header.songBase, 0xFFFF);

	initialize_state();
	SendMessage(tab_hwnd[current_tab], WM_SONG_IMPORTED, 0, 0);
	scope(failure) {
		spc = backup_spc;
		sample_ptr_base = original_sample_ptr_base;
	}
}

void export_() {
	if (cur_song.order_length < 1) {
		MessageBox2("No song loaded.", "Export SPC", MB_ICONEXCLAMATION);
		return;
	}
	const data = spc[cur_song.address .. cur_song.address + compile_song(&cur_song)];

	string file = saveFilePrompt("EarthBound Music files (*.ebm)\0*.ebm\0", "ebm");
	if (file == "") return;

	auto f = File(file, "wb");
	const header = [cast(ushort)data.length, cast(ushort)cur_song.address];
	f.rawWrite(header);
	f.rawWrite(data);
}

private immutable blankSPC = cast(immutable(ubyte)[])import("blank.spc");

static void export_spc() {
	if (cur_song.order_length < 1) {
		MessageBox2("No song loaded.", "Export SPC", MB_ICONEXCLAMATION);
		return;
	}
	string file = saveFilePrompt("SPC files (*.spc)\0*.spc\0", "spc");
	if (!file) {
		return;
	}
	auto f = File(file, "wb");
	const spc_size = blankSPC.length;
	const WORD header_size = 0x100;
	const WORD footer_size = 0x100;

	// Copy blank SPC to byte array
	ubyte[] new_spc = new ubyte[](spc_size);
	new_spc[0 .. spc_size] = blankSPC;

	// Copy packs/blocks to byte array
	ushort[2][4] usedRanges;
	usedRanges[0] = [ushort(0x500), ushort(0x468B)]; // program

	infof("Saving program to %04X (%04X)", usedRanges[0][0], usedRanges[0][1]);

	const savedAddress = cur_song.address;
	cur_song.address = 0x4700;
	scope(exit) cur_song.address = savedAddress;
	const sequence = getSequenceData();
	usedRanges[1] = [ushort(0x4700), cast(ushort)(0x4700 + sequence.length)];
	infof("Saving sequence to %04X (%04X)", usedRanges[1][0], usedRanges[1][1]);
	/// write instruments

	new_spc[0x100 + cur_song.address .. 0x100 + cur_song.address + sequence.length] = sequence;
	auto tmpInstrLocation = cast(ushort)(usedRanges[1][1] + 1);
	const instruments = getInstrumentData();
	usedRanges[2] = [tmpInstrLocation, cast(ushort)(tmpInstrLocation + instruments.length)];
	new_spc[0x100 + tmpInstrLocation .. 0x100 + tmpInstrLocation + instruments.length] = instruments;
	infof("Saving instruments to %04X (%04X)", usedRanges[2][0], usedRanges[2][1]);

	/// write samples

	const tmpSampleDirectory = cast(ushort)(((usedRanges[2][1] >> 8) + 1) << 8);
	ushort[2][] sampleDirectoryCopy = sampleDirectory.dup;
	usedRanges[3] = [tmpSampleDirectory, cast(ushort)(tmpSampleDirectory + sampleDirectoryCopy.length * (ushort[2].sizeof))];
	infof("Saving sample directory to %04X (%04X)", usedRanges[3][0], usedRanges[3][1]);
	ushort sampleStart = cast(ushort)(usedRanges[3][1] + 1);
	size_t sampleOffset;
	ushort[ushort] sampleMap;
	foreach (ref samplePair; sampleDirectoryCopy) {
		if (samplePair[0] == 0 || samplePair[0] == 0xffff) {
			continue;
		}
		if (samplePair[0] !in samples) {
			continue;
		}
		const diff = samplePair[1] - samplePair[0];
		const sample = samples[samplePair[0]];
		const orig = samplePair[0];
		infof("Rewriting %04X to %04X", orig, sampleStart);
		samplePair[0] = sampleStart;
		samplePair[1] = cast(ushort)(sampleStart + diff);
		if (orig !in sampleMap) {
			infof("%s", sampleMap);
			sampleMap[orig] = sampleStart;
			infof("Saving sample data %04X to %04X (%04X)", orig, sampleStart, sampleStart + sample.length);
			new_spc[0x100 + sampleStart .. 0x100 + sampleStart + sample.length] = sample;
			sampleStart += sample.length;
		}
	}
	new_spc[0x100 + tmpSampleDirectory .. 0x100 + tmpSampleDirectory + sampleDirectoryCopy.length * (ushort[2].sizeof)] = cast(ubyte[])sampleDirectoryCopy;


	// Set pattern repeat location
	const ushort repeat_address = cast(ushort)(cur_song.address + 0x2*cur_song.repeat_pos);
	(cast(ushort[])(new_spc[0x140 .. 0x142]))[0] = repeat_address;

	// Set sample directory location
	new_spc[0x62A] = tmpSampleDirectory >> 8;

	// Set instrument location
	new_spc[0xA72] = tmpInstrLocation & 0xFF;
	new_spc[0xA75] = tmpInstrLocation >> 8;

	// Set BGM to load
	const ubyte bgm = 1;
	new_spc[0x1F4] = bgm;

	// Save byte array to file
	f.rawWrite(new_spc);
}
private ubyte[] getInstrumentData() nothrow {
	return spc[inst_base .. inst_base + 6 * 128];
}
private ubyte[] getSampleDirectory() nothrow {
	return cast(ubyte[])sampleDirectory;
}
private ubyte[] getSequenceData() nothrow {
	return spc[cur_song.address .. cur_song.address + compile_song(&cur_song)];
}
static void export_nspc() {
	if (cur_song.order_length < 1) {
		MessageBox2("No song loaded.", "Export SPC", MB_ICONEXCLAMATION);
		return;
	}
	string filename = saveFilePrompt("NSPC files (*.nspc)\0*.nspc\0", "nspc");
	if (!filename) {
		return;
	}
	import nspcplay;

	auto file = File(filename, "wb").lockingBinaryWriter;
	NSPCWriter writer;
	writer.header.songBase = cur_song.address;
	writer.header.instrumentBase = cast(ushort)inst_base;
	writer.header.sampleBase = sample_ptr_base;
	writer.header.volumeTable = VolumeTable.hal1;
	writer.header.releaseTable = ReleaseTable.hal1;
	// instruments
	writer.packs ~= Pack(cast(ushort)inst_base, getInstrumentData());
	// samples
	//writer.packs ~= Pack(cast(ushort)sample_ptr_base, getSampleData());
	// song
	writer.packs ~= Pack(cast(ushort)cur_song.address, getSequenceData());
	//writer.tags[] = ;
	writer.toBytes(file);
}
