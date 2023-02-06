
import core.stdc.stdio;
import core.stdc.string;
import core.stdc.errno;
import core.stdc.stdlib;
import core.sys.windows.windows;
import core.sys.windows.commdlg;
import core.sys.windows.commctrl;

import std.algorithm.comparison : min;
import std.exception;
import std.format;
import std.experimental.logger;
import std.stdio;
import std.string;
import ebmusv2;
import misc;
import packs;
import structs;
import help;
import brr;
import loadrom;
import metadata;
import play;
import song;
import win32.bgmlist;
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
__gshared ubyte[3] packs_loaded = [ 0xFF, 0xFF, 0xFF ];
__gshared ptrdiff_t current_block = -1;
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
	char *file = open_dialog(&GetOpenFileNameA,
		cast(char*)"SPC Savestates (*.spc)\0*.spc\0All Files\0*.*\0".ptr,
		null,
		OFN_FILEMUSTEXIST | OFN_HIDEREADONLY);
	if (!file) return;

	FILE *f = fopen(file, "rb");
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
		free_samples();
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
			free_samples();
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
	char *file = open_dialog(&GetOpenFileNameA,
		cast(char*)"NSPC File (*.nspc)\0*.nspc\0All Files\0*.*\0".ptr,
		null,
		OFN_FILEMUSTEXIST | OFN_HIDEREADONLY);
	if (!file) return;
	import nspcplay;
	import std.file : read;
	auto nspcFile = cast(ubyte[])read(file.fromStringz);
	ubyte[0x10000] backup_spc = spc;
	WORD original_sample_ptr_base = sample_ptr_base;

	const header = (cast(NSPCFileHeader[])(nspcFile[0 .. NSPCFileHeader.sizeof]))[0];
	loadAllSubpacks(spc[], nspcFile[NSPCFileHeader.sizeof .. $]);

	//samples
	sample_ptr_base = header.sampleBase;
	free_samples();
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

void export_() nothrow {
	block *b = save_cur_song_to_pack();
	if (!b) {
		MessageBox2("No song loaded", "Export", MB_ICONEXCLAMATION);
		return;
	}

	char *file = open_dialog(&GetSaveFileNameA, cast(char*)"EarthBound Music files (*.ebm)\0*.ebm\0".ptr, cast(char*)"ebm".ptr, OFN_OVERWRITEPROMPT);
	if (!file) return;

	FILE *f = fopen(file, "wb");
	if (!f) {
		MessageBox2(strerror(errno).fromStringz, "Export", MB_ICONEXCLAMATION);
		return;
	}
	fwrite(b, 4, 1, f);
	fwrite(b.data, b.size, 1, f);
	fclose(f);
}

private immutable blankSPC = cast(immutable(ubyte)[])import("blank.spc");

static void export_spc() nothrow {
	if (cur_song.order_length < 1) {
		MessageBox2("No song loaded.", "Export SPC", MB_ICONEXCLAMATION);
	} else {
		char *file = open_dialog(&GetSaveFileNameA, cast(char*)"SPC files (*.spc)\0*.spc\0".ptr, cast(char*)"spc".ptr, OFN_OVERWRITEPROMPT);
		if (file) {
			FILE *f = fopen(file, "wb");
			if (!f) {
				MessageBox2(strerror(errno).fromStringz, "Export SPC", MB_ICONEXCLAMATION);
			} else {
				const spc_size = blankSPC.length;
				const WORD header_size = 0x100;
				const WORD footer_size = 0x100;

				// Copy blank SPC to byte array
				ubyte* new_spc = cast(ubyte*)malloc(spc_size);
				new_spc[0 .. spc_size] = blankSPC;

				// Copy packs/blocks to byte array
				for (int pack_ = 0; pack_ < 3; pack_++) {
					if (packs_loaded[pack_] < NUM_PACKS) {
						pack *p = load_pack(packs_loaded[pack_]);
						for (int block_ = 0; block_ < p.block_count; block_++) {
							block *b = &p.blocks[block_];

							// Copy block to new_spc
							const int size = min(b.size, spc_size - b.spc_address - footer_size);
							memcpy(new_spc + header_size + b.spc_address, b.data, size);

							if (size > spc_size - footer_size) {
								assumeWontThrow(infof("SPC pack %d block %d too large.\n", packs_loaded[pack_], block_));
							}
						}
					}
				}

				// Set pattern repeat location
				const WORD repeat_address = cast(WORD)(cur_song.address + 0x2*cur_song.repeat_pos);
				memcpy(new_spc + 0x140, &repeat_address, 2);

				// Set BGM to load
				const ubyte bgm = cast(ubyte)(selected_bgm + 1);
				memcpy(new_spc + 0x1F4, &bgm, 1);

				// Save byte array to file
				fwrite(new_spc, spc_size, 1, f);
				fclose(f);
			}
		}
	}
}
static void export_nspc() {
	if (cur_song.order_length < 1) {
		MessageBox2("No song loaded.", "Export SPC", MB_ICONEXCLAMATION);
		return;
	}
	char[] filename = open_dialog(&GetSaveFileNameA, cast(char*)"NSPC files (*.nspc)\0*.nspc\0".ptr, cast(char*)"nspc".ptr, OFN_OVERWRITEPROMPT).fromStringz;
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
	writer.packs ~= Pack(cast(ushort)inst_base, spc[inst_base .. inst_base + 4 * 128]);
	// samples
	writer.packs ~= Pack(cast(ushort)sample_ptr_base, spc[sample_ptr_base .. maxSamplePosition + 1]);
	// song
	block *b = save_cur_song_to_pack();
	const buf = b.data[0 .. b.size];

	writer.packs ~= Pack(cast(ushort)b.spc_address, buf);
	//writer.tags[] = ;
	writer.toBytes(file);
}

BOOL save_all_packs() nothrow {
	char[60] buf;
	save_cur_song_to_pack();
	int packs = 0;
	BOOL success = TRUE;
	for (int i = 0; i < NUM_PACKS; i++) {
		if (inmem_packs[i].status & IPACK_CHANGED) {
			BOOL saved = save_pack(i);
			success &= saved;
			packs += saved;
		}
	}
	if (packs) {
		SendMessageA(tab_hwnd[current_tab], WM_PACKS_SAVED, 0, 0);
		MessageBox2(assumeWontThrow(sformat(buf[], "%d pack(s) saved", packs)), "Save", MB_OK);
	}
	try {
		save_metadata();
	} catch(Exception e) {
		MessageBox2(e.msg, filename, MB_ICONEXCLAMATION);
	}
	return success;
}
