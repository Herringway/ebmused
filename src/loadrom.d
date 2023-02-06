import core.stdc.stdio;
import core.stdc.stdlib;
import core.stdc.string;
import core.stdc.errno;
import core.sys.windows.windows : IDCANCEL, IDYES, MB_ICONERROR, MB_ICONEXCLAMATION, MB_YESNOCANCEL, MF_ENABLED, MF_GRAYED, SetWindowTextW;
import std.exception;
import std.format;
import std.stdio;
import std.string;
import std.utf;
import ebmusv2;
import structs;
import misc;
import win32.dialogs;
import win32.handles;
import win32.id;
import win32.misc;
import packs;
import main;
import brr;
import metadata;
import play;
import ranges;
import song;

__gshared File rom;
__gshared int rom_size;
__gshared int rom_offset;
__gshared string rom_filename;

__gshared ubyte[3][NUM_SONGS] pack_used;
__gshared ushort[NUM_SONGS] song_address;
__gshared pack[NUM_PACKS] rom_packs;
__gshared pack[NUM_PACKS] inmem_packs;

private string skip_dirname(string filename) nothrow {
	string original = filename;
	foreach (idx, char c; filename) {
		if (c == '/' || c == '\\') {
			filename = filename[idx + 1 .. $];
		}
	}
	return filename;
}

__gshared uint[256] crc_table;

static void init_crc() nothrow {
	for (int i = 0; i < 256; i++) {
		uint crc = i;
		for (int j = 8; j; j--)
			if (crc & 1)
				crc = (crc >> 1) ^ 0xEDB88320;
			else
				crc = (crc >> 1);
		crc_table[i] = crc;
	}
}

static uint update_crc(uint crc, ubyte *block, int size) nothrow {
	do {
		crc = (crc >> 8) ^ crc_table[(crc ^ *block++) & 0xFF];
	} while (--size);
	return crc;
}

immutable ubyte[3] rom_menu_cmds = [
	ID_SAVE_ALL, ID_CLOSE, 0
];

bool close_rom() {
	if (!rom.isOpen) return true;

	save_cur_song_to_pack();
	int unsaved_packs = 0;
	for (int i = 0; i < NUM_PACKS; i++)
		if (inmem_packs[i].status & IPACK_CHANGED)
			unsaved_packs++;
	if (unsaved_packs) {

		char[70] buf;
		char[] slice;
		if (unsaved_packs == 1)
			slice = assumeWontThrow(sformat(buf[], "A pack has unsaved changes.\nDo you want to save?"));
		else
			slice = assumeWontThrow(sformat(buf[], "%d packs have unsaved changes.\nDo you want to save?", unsaved_packs));

		int action = MessageBox2(slice, "Close", MB_ICONEXCLAMATION | MB_YESNOCANCEL);
		if (action == IDCANCEL || (action == IDYES && !save_all_packs()))
			return false;
	}
	try {
		save_metadata();
	} catch (Exception e) {
		throw new EbmusedWarningException(e.msg, filename.fromStringz.toUTF8);
	}
	try {
		rom.close();
	} catch (Exception) {}
	rom_filename = null;
	enable_menu_items(&rom_menu_cmds[0], MF_GRAYED);
	free(areas);
	free_metadata();
	initialize_state();
	for (int i = 0; i < NUM_PACKS; i++) {
		free(rom_packs[i].blocks);
		if (inmem_packs[i].status & IPACK_INMEM)
			free_pack(&inmem_packs[i]);
	}
	memset(&packs_loaded[0], 0xFF, 3);
	current_block = -1;
	return true;
}

bool open_rom(string filename, bool readonly) {
	File f;
	try {
		f = File(filename, readonly ? "rb" : "r+b");
	} catch (Exception e) {
		MessageBox2(e.msg, "Can't open file", MB_ICONEXCLAMATION);
		return false;
	}

	if (!close_rom())
		return false;

	free_song(&cur_song);
	song_playing = false;

	rom_size = cast(int)f.size;
	rom_offset = rom_size & 0x200;
	if (rom_size < 0x300000) {
		MessageBox2("An EarthBound ROM must be at least 3 MB", "Can't open file", MB_ICONEXCLAMATION);
		f.close();
		return false;
	}
	rom = f;
	rom_filename = filename;
	enable_menu_items(&rom_menu_cmds[0], MF_ENABLED);

	init_areas();
	change_range(0xBFFE00 + rom_offset, 0xBFFC00 + rom_offset + rom_size, AREA_NOT_IN_FILE, AREA_NON_SPC);

	string bfile = skip_dirname(filename);
	const wchar[] title = format!"%s - %s\0"w(bfile, "EarthBound Music Editor");
	SetWindowTextW(hwndMain, &title[0]);

	f.seek(BGM_PACK_TABLE + rom_offset, SEEK_SET);
	f.rawRead(pack_used[]);
	// pack pointer table follows immediately after
	for (int i = 0; i < NUM_PACKS; i++) {
		int addr = f.getc() << 16;
		addr |= f.getw();
		rom_packs[i].start_address = addr;
	}

	f.seek(SONG_POINTER_TABLE + rom_offset, SEEK_SET);
	f.rawRead(song_address[]);

	init_crc();
	for (int i = 0; i < NUM_PACKS; i++) {
		int size;
		int count = 0;
		uint crc;
		block *blocks = null;
		bool valid = true;
		pack *rp = &rom_packs[i];

		int offset = rp.	start_address - 0xC00000 + rom_offset;
		if (offset < rom_offset || offset >= rom_size) {
			valid = false;
			goto bad_pointer;
		}

		f.seek(offset, SEEK_SET);
		crc = ~0;
		while ((size = f.getw()) > 0) {
			int spc_addr = f.getw();
			if (spc_addr + size > 0x10000) { valid = false; break; }
			offset += 4 + size;
			if (offset > rom_size) { valid = false; break; }

			count++;
			blocks = cast(block*)realloc(blocks, block.sizeof * count);
			blocks[count-1].size = cast(ushort)size;
			blocks[count-1].spc_address = cast(ushort)spc_addr;

/*			if (spc_addr == 0x0500) {
				int back = ftell(f);
				fseek(f, 0x2E4A - 0x500, SEEK_CUR);
				fread(song_address, NUM_SONGS, 2, f);
				fseek(f, back, SEEK_SET);
			}*/

			f.rawRead(spc[spc_addr .. spc_addr + size]);
			crc = update_crc(crc, cast(ubyte *)&size, 2);
			crc = update_crc(crc, cast(ubyte *)&spc_addr, 2);
			crc = update_crc(crc, &spc[spc_addr], size);
		}
		crc = ~update_crc(crc, cast(ubyte *)&size, 2);
bad_pointer:
		change_range(rp.start_address, offset + 2 + 0xC00000 - rom_offset,
			AREA_NON_SPC, i);
		rp.status = valid ? crc != pack_orig_crc[i] : 2;
		rp.block_count = count;
		rp.blocks = blocks;
		inmem_packs[i].status = 0;
	}
	load_metadata();
	return true;
}
