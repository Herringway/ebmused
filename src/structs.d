
import core.stdc.config;

// structure used for track or subroutine
// "size" does not include the ending [00] byte
struct track {
	int size;
	ubyte *track; // NULL for inactive track
};

alias song = Song;
struct Song {
	ushort address;
	ubyte changed;
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
	ubyte *ptr;
	ubyte *sub_ret;
	int sub_start;
	ubyte sub_count;
	ubyte note_len;
};

struct slider {
	ushort cur, delta;
	ubyte cycles, target;
};

struct channel_state {
	ubyte *ptr;

	int next; // time left in note

	slider note; ubyte cur_port_start_ctr;
	ubyte note_len, note_style;

	ubyte note_release; // time to release note, in cycles

	int sub_start; // current subroutine number
	ubyte *sub_ret; // where to return to after sub
	ubyte sub_count; // number of loops

	ubyte inst; // instrument
	ubyte inst_adsr1;
	ubyte finetune;
	byte transpose;
	slider panning; ubyte pan_flags;
	slider volume;
	ubyte total_vol;
	byte left_vol, right_vol;

	ubyte port_type, port_start, port_length, port_range;
	ubyte vibrato_start, vibrato_speed, vibrato_max_range, vibrato_fadein;
	ubyte tremolo_start, tremolo_speed, tremolo_range;

	ubyte vibrato_phase, vibrato_start_ctr, cur_vib_range;
	ubyte vibrato_fadein_ctr, vibrato_range_delta;
	ubyte tremolo_phase, tremolo_start_ctr;

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
	ubyte first_CA_inst; // set with FA
	ubyte repeat_count;
	int ordnum;
	int patpos; // Number of cycles since top of pattern
};

struct sample {
	short *data;
	int length;
	int loop_len;
};

struct block {
	ushort size, spc_address;
	ubyte *data; // only used for inmem packs
};
