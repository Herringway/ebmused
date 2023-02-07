import core.stdc.stdio;
import core.stdc.stdlib;
import core.stdc.string;
import core.runtime;
import std.experimental.logger;
import std.range;
import std.string;
import structs;
import misc;
import main;
import parser;
import play;

void validate_track(ubyte *data, int size, bool is_sub) {
	for (int pos = 0; pos < size; ) {
		int byte_ = data[pos];
		int next = pos + 1;

		if (byte_ < 0x80) {
			if (byte_ == 0) {
				throw new EbmusedWarningException("Track can not contain [00]", "");
			}
			if (next != size && data[next] < 0x80) next++;
			if (next == size) {
				throw new EbmusedWarningException("Track can not end with note-length code", "");
			}
		} else if (byte_ >= 0xE0) {
			if (byte_ == 0xFF) {
				throw new EbmusedWarningException("Invalid code [FF]", "");
			}
			next += code_length.ptr[byte_ - 0xE0];
			if (next > size) {
				throw new EbmusedWarningException(format!"Incomplete code [%(%02X %) %(?? %)]"(data[pos .. size], iota(next - size)), "");
			}

			if (byte_ == 0xEF) {
				if (is_sub) {
					throw new EbmusedWarningException("Can't call sub from within a sub", "");
				}
				int sub = *cast(ushort *)&data[pos+1];
				if (sub >= cur_song.subs) {
					throw new EbmusedWarningException(format!"Subroutine %d not present"(sub), "");
				}
				if (data[pos+3] == 0) {
					throw new EbmusedWarningException("Subroutine loop count can not be 0", "");
				}
			}
		}

		pos = next;
	}
}

int compile_song(Song *s) nothrow {
	int i;

	// Put order
	ushort *wout = cast(ushort *)&spc[s.address];
	int first_pat = s.address + s.order_length*2 + (s.repeat ? 6 : 2);
	for (i = 0; i < s.order_length; i++)
		*wout++ = cast(ushort)(first_pat + (s.order[i] << 4));
	if (s.repeat) {
		*wout++ = cast(ushort)s.repeat;
		*wout++ = cast(ushort)(s.address + s.repeat_pos*2);
	}
	*wout++ = 0;

	// Put patterns and tracks
	ubyte *tracks_start = &spc[first_pat + (s.patterns << 4)];
	ubyte *tout = tracks_start;
	for (i = 0; i < s.patterns; i++) {
		int first = 1;
		for (int ch = 0; ch < 8; ch++) {
			track *t = &s.pattern[i][ch];
			if (t.track == null) {
				*wout++ = 0;
			} else {
				*wout++ = cast(ushort)(tout - &spc[0]);
				// Only the first track in a pattern is 0 terminated
				int size = t.size + first;
				memcpy(tout, t.track, size);
				tout += size;
				first = 0;
			}
		}
	}
	// There's another 0 before subs start
	*tout++ = 0;
	ubyte *tracks_end = tout;

	// Convert subroutine numbers into addresses, and append the subs as
	// they are used. This is consistent with the way the original songs are:
	// subs are always in order of first use, and there are no unused subs.
	ushort *sub_table = cast(ushort*)calloc(ushort.sizeof, s.subs);
	for (ubyte *pos = tracks_start; pos < tracks_end; pos = next_code(pos)) {
		if (*pos == 0xEF) {
			int sub = *cast(ushort *)(pos + 1);
			if (sub >= s.subs) abort(); // can't happen

			if (sub_table[sub] == 0) {
				track *t = &s.sub[sub];
				sub_table[sub] = cast(ushort)(tout - &spc[0]);
				memcpy(tout, t.track, t.size + 1);
				tout += t.size + 1;
			}
			*cast(ushort *)(pos + 1) = sub_table[sub];
		}
	}
	free(sub_table);

	return cast(int)((tout - &spc[0]) - s.address);
}

void decompile_song(Song *s, int start_addr, int end_addr) {
	ushort *sub_table;
	int first_pattern;
	int tracks_start;
	int tracks_end;
	int pat_bytes;
	s.address = cast(ushort)start_addr;
	s.changed = false;

	// Get order length and repeat info (at this point, we don't know how
	// many patterns there are, so the pattern pointers aren't validated yet)
	ushort *wp = cast(ushort *)&spc[start_addr];
	while (*wp >= 0x100) wp++;
	s.order_length = cast(int)(wp - cast(ushort *)&spc[start_addr]);
	if (s.order_length == 0) {
		throw new Exception("Order length is 0");
	}
	scope(failure) {
		s.order_length = 0;
	}
	s.repeat = *wp++;
	if (s.repeat == 0) {
		s.repeat_pos = 0;
	} else {
		int repeat_off = *wp++ - start_addr;
		if (repeat_off & 1 || repeat_off < 0 || repeat_off >= s.order_length*2) {
			throw new Exception(format!"Bad repeat pointer: %x"(repeat_off + start_addr));
		}
		if (*wp++ != 0) {
			throw new Exception("Repeat not followed by end of song");
		}
		s.repeat_pos = repeat_off >> 1;
	}

	first_pattern = cast(int)(cast(ubyte *)wp - &spc[0]);

	// locate first track, determine number of patterns
	while ((cast(ubyte *)wp)+1 < &spc[end_addr] && *wp == 0) wp++;
	if ((cast(ubyte *)wp)+1 >= &spc[end_addr]) {
		// no tracks in the song
		tracks_start = end_addr - 1;
	} else {
		tracks_start = *wp;
	}

	pat_bytes = tracks_start - first_pattern;
	if (pat_bytes <= 0 || pat_bytes & 15) {
			throw new Exception(format!"Bad first track pointer: %x"(tracks_start));
	}

	if ((cast(ubyte *)wp)+1 >= &spc[end_addr]) {
		// no tracks in the song
		tracks_end = end_addr - 1;
	} else {
		// find the last track
		int tp, tpp = tracks_start;
		while ((tp = *cast(ushort *)&spc[tpp -= 2]) == 0) {}

		if (tp < tracks_start || tp >= end_addr) {
			throw new Exception(format!"Bad last track pointer: %x"(tp));
		}


		// is the last track the first one in its pattern?
		bool first = true;
		int chan = (tpp - first_pattern) >> 1 & 7;
		for (; chan; chan--)
			first &= *cast(ushort *)&spc[tpp -= 2] == 0;

		ubyte *end = &spc[tp];
		while (*end) end = next_code(end);
		end += first;
		tracks_end = cast(ushort)(end - &spc[0]);
	}

	// Now the number of patterns is known, so go back and get the order
	s.order = cast(int*)malloc(int.sizeof * s.order_length);
	scope(failure) {
		free(s.order);
	}
	wp = cast(ushort *)&spc[start_addr];
	for (int i = 0; i < s.order_length; i++) {
		int pat = *wp++ - first_pattern;
		if (pat < 0 || pat >= pat_bytes || pat & 15) {
			throw new Exception(format!"Bad pattern pointer: %x"(pat + first_pattern));
		}
		s.order[i] = pat >> 4;
	}

	sub_table = null;
	scope(exit) {
		if (sub_table !is null) {
			free(sub_table);
		}
	}
	s.patterns = pat_bytes >> 4;
	s.pattern = cast(track[8]*)calloc((*s.pattern).sizeof, s.patterns);
	scope(failure) {
		free(s.pattern);
		for (int trk = 0; trk < s.patterns * 8; trk++) {
			free(s.pattern[0][trk].track);
		}
	}
	s.subs = 0;
	s.sub = null;
	scope(failure) {
		if (s.sub !is null) {
			free(s.sub);
		}
		for (int trk = 0; trk < s.subs; trk++) {
			free(s.sub[trk].track);
		}
	}

	wp = cast(ushort *)&spc[first_pattern];
	for (int trk = 0; trk < s.patterns * 8; trk++) {
		track *t = &s.pattern[0][0] + trk;
		int start = *wp++;
		if (start == 0) continue;
		if (start < tracks_start || start >= tracks_end) {
			throw new Exception(format!"Bad track pointer: %x"(start));
		}

		// Go through track list (patterns) and find first track that has an address higher than us.
		// If we find a track after us, we'll assume that this track doesn't overlap with that one.
		// If we don't find one, then next will remain at 0x10000 and we will search until the
		// end of memory to find a 00 byte to terminate the track.
		int next = 0x10000; // offset of following track
		for (int track_ind = 0; track_ind < (s.patterns * 8); track_ind += 1) {
			int track_addr = (cast(ushort *)(&spc[first_pattern]))[track_ind];
			if (track_addr < next && track_addr > start) {
				next = track_addr;
			}
		}
		// Determine the end of the track.
		ubyte *track_end;
		for (track_end = &spc[start]; track_end < &spc.ptr[next] && *track_end != 0; track_end = next_code(track_end)) {}

		t.size = cast(int)((track_end - &spc[0]) - start);
		t.track = cast(ubyte*)memcpy(malloc(t.size + 1), &spc[start], t.size);
		t.track[t.size] = 0;

		for (ubyte *p = t.track; p < t.track + t.size; p = next_code(p)) {
			if (*p != 0xEF) continue;
			int sub_ptr = *cast(ushort *)(p + 1);
			int sub_entry;

			// find existing entry in sub_table
			for (sub_entry = 0; sub_entry < s.subs && sub_table[sub_entry] != sub_ptr; sub_entry++) {}
			if (sub_entry == s.subs) {
				// sub_entry doesn't already exist in sub_table; create it
				sub_entry = s.subs++;

				sub_table = cast(ushort*)realloc(sub_table, ushort.sizeof * s.subs);
				sub_table[sub_entry] = cast(ushort)sub_ptr;

				s.sub = cast(track*)realloc(s.sub, track.sizeof * s.subs);
				track *st = &s.sub[sub_entry];

				ubyte *substart = &spc[sub_ptr];
				ubyte *subend = substart;
				while (*subend != 0) subend = next_code(subend);
				st.size = cast(int)(subend - substart);
				st.track = cast(ubyte*)memcpy(malloc(st.size + 1), substart, st.size + 1);
				validate_track(st.track, st.size, true);
			}
			*cast(ushort *)(p + 1) = cast(ushort)sub_entry;
		}
		validate_track(t.track, t.size, false);
	}
}

void free_song(Song *s) nothrow {
	int pat, ch, sub;
	if (!s.order_length) return;
	s.changed = false;
	free(s.order);
	for (pat = 0; pat < s.patterns; pat++)
		for (ch = 0; ch < 8; ch++)
			free(s.pattern[pat][ch].track);
	free(s.pattern);
	for (sub = 0; sub < s.subs; sub++)
		free(s.sub[sub].track);
	free(s.sub);
	s.order_length = 0;
}
