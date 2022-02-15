
import core.stdc.config;

version = CreateWindow;
version(CreateWindow) {
	import core.sys.windows.windows;
} else {
	alias BYTE = ubyte;
	alias WORD = ushort;
	alias DWORD = cpp_ulong;
	alias BOOL = int;
	enum FALSE = 0;
	enum TRUE = 1;
	alias HWND = void *;
}

// structure used for track or subroutine
// "size" does not include the ending [00] byte
struct track {
	int size;
	BYTE *track; // NULL for inactive track
};

alias song = Song;
struct Song {
	WORD address;
	BYTE changed;
	int order_length;
	int *order;
	int repeat, repeat_pos;
	int patterns;
	track[8]* pattern;
	int subs;
	track *sub;
};

alias parser = Parser;
struct Parser {
	BYTE *ptr;
	BYTE *sub_ret;
	int sub_start;
	BYTE sub_count;
	BYTE note_len;
};

struct slider {
	WORD cur, delta;
	BYTE cycles, target;
};

	struct channel_state {
		BYTE *ptr;

		int next; // time left in note

		slider note; BYTE cur_port_start_ctr;
		BYTE note_len, note_style;

		BYTE note_release; // time to release note, in cycles

		int sub_start; // current subroutine number
		BYTE *sub_ret; // where to return to after sub
		BYTE sub_count; // number of loops

		BYTE inst; // instrument
		BYTE inst_adsr1;
		BYTE finetune;
		byte transpose;
		slider panning; BYTE pan_flags;
		slider volume;
		BYTE total_vol;
		byte left_vol, right_vol;

		BYTE port_type, port_start, port_length, port_range;
		BYTE vibrato_start, vibrato_speed, vibrato_max_range, vibrato_fadein;
		BYTE tremolo_start, tremolo_speed, tremolo_range;

		BYTE vibrato_phase, vibrato_start_ctr, cur_vib_range;
		BYTE vibrato_fadein_ctr, vibrato_range_delta;
		BYTE tremolo_phase, tremolo_start_ctr;

		sample *samp;
		int samp_pos, note_freq;

		double env_height; // envelope height
		double decay_rate;
	}
struct song_state {
	channel_state[16] chan;
	byte transpose;
	slider volume;
	slider tempo;
	int next_timer_tick, cycle_timer;
	BYTE first_CA_inst; // set with FA
	BYTE repeat_count;
	int ordnum;
	int patpos; // Number of cycles since top of pattern
};

struct sample {
	short *data;
	int length;
	int loop_len;
};

struct block {
	WORD size, spc_address;
	BYTE *data; // only used for inmem packs
};

// rom_packs contain info about the pack as it stands in the ROM file
// .status is one of these constants:
enum RPACK_ORIGINAL = 0;
enum RPACK_MODIFIED = 1;
enum RPACK_INVALID = 2;
enum RPACK_SAVED = 3;

// inmem_packs contain info about the pack as it currently is in the editor
// .status is a bitmask of these constants:
enum IPACK_INMEM = 1;	// blocks[i].data valid if set
enum IPACK_CHANGED = 2;
struct pack {
	int start_address;
	int status;	// See constants above
	int block_count;
	block *blocks;
};
