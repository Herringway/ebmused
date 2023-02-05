import core.stdc.stdio;
import core.stdc.stdlib;
import core.stdc.string;
import std.string;
import ebmusv2;
import structs;
import win32.misc;
import main;
import parser;
import play;

__gshared char[60] errbuf;
__gshared const(char)* decomp_error;


const(char)* internal_validate_track(ubyte *data, int size, bool is_sub) nothrow {
	for (int pos = 0; pos < size; ) {
		int byte_ = data[pos];
		int next = pos + 1;

		if (byte_ < 0x80) {
			if (byte_ == 0) return "Track can not contain [00]";
			if (next != size && data[next] < 0x80) next++;
			if (next == size) return "Track can not end with note-length code";
		} else if (byte_ >= 0xE0) {
			if (byte_ == 0xFF) return "Invalid code [FF]";
			next += code_length.ptr[byte_ - 0xE0];
			if (next > size) {
				char *p = strcpy(&errbuf[0], "Incomplete code: [") + 18;
				for (; pos < size; pos++)
					p += sprintf(p, "%02X ", data[pos]);
				for (; pos < next; pos++)
					p += sprintf(p, "?? ");
				p[-1] = ']';
				return &errbuf[0];
			}

			if (byte_ == 0xEF) {
				if (is_sub) return "Can't call sub from within a sub";
				int sub = *cast(ushort *)&data[pos+1];
				if (sub >= cur_song.subs) {
					sprintf(&errbuf[0], "Subroutine %d not present", sub);
					return &errbuf[0];
				}
				if (data[pos+3] == 0) return "Subroutine loop count can not be 0";
			}
		}

		pos = next;
	}
	return null;
}

bool validate_track(ubyte *data, int size, bool is_sub) nothrow {
	const(char)* err = internal_validate_track(data, size, is_sub);
	if (err) {
		MessageBox2(err.fromStringz, [], 48/*MB_ICONEXCLAMATION*/);
		return false;
	}
	return true;
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

void decompile_song(Song *s, int start_addr, int end_addr) nothrow {
	ushort *sub_table;
	int first_pattern;
	int tracks_start;
	int tracks_end;
	int pat_bytes;
	const(char)* error = &errbuf[0];
	s.address = cast(ushort)start_addr;
	s.changed = false;

	// Get order length and repeat info (at this point, we don't know how
	// many patterns there are, so the pattern pointers aren't validated yet)
	ushort *wp = cast(ushort *)&spc[start_addr];
	while (*wp >= 0x100) wp++;
	s.order_length = cast(int)(wp - cast(ushort *)&spc[start_addr]);
	if (s.order_length == 0) {
		error = "Order length is 0";
		goto error1;
	}
	s.repeat = *wp++;
	if (s.repeat == 0) {
		s.repeat_pos = 0;
	} else {
		int repeat_off = *wp++ - start_addr;
		if (repeat_off & 1 || repeat_off < 0 || repeat_off >= s.order_length*2) {
			sprintf(&errbuf[0], "Bad repeat pointer: %x", repeat_off + start_addr);
			goto error1;
		}
		if (*wp++ != 0) {
			error = "Repeat not followed by end of song";
			goto error1;
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
		sprintf(&errbuf[0], "Bad first track pointer: %x", tracks_start);
		goto error1;
	}

	if ((cast(ubyte *)wp)+1 >= &spc[end_addr]) {
		// no tracks in the song
		tracks_end = end_addr - 1;
	} else {
		// find the last track
		int tp, tpp = tracks_start;
		while ((tp = *cast(ushort *)&spc[tpp -= 2]) == 0) {}

		if (tp < tracks_start || tp >= end_addr) {
			sprintf(&errbuf[0], "Bad last track pointer: %x", tp);
			goto error1;
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
	wp = cast(ushort *)&spc[start_addr];
	for (int i = 0; i < s.order_length; i++) {
		int pat = *wp++ - first_pattern;
		if (pat < 0 || pat >= pat_bytes || pat & 15) {
			sprintf(&errbuf[0], "Bad pattern pointer: %x", pat + first_pattern);
			goto error2;
		}
		s.order[i] = pat >> 4;
	}

	sub_table = null;
	s.patterns = pat_bytes >> 4;
	s.pattern = cast(track[8]*)calloc((*s.pattern).sizeof, s.patterns);
	s.subs = 0;
	s.sub = null;

	wp = cast(ushort *)&spc[first_pattern];
	for (int trk = 0; trk < s.patterns * 8; trk++) {
		track *t = &s.pattern[0][0] + trk;
		int start = *wp++;
		if (start == 0) continue;
		if (start < tracks_start || start >= tracks_end) {
			sprintf(&errbuf[0], "Bad track pointer: %x", start);
			goto error3;
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
				const(char)* e = internal_validate_track(st.track, st.size, true);
				if (e) {
					error = e;
					goto error3;
				}
			}
			*cast(ushort *)(p + 1) = cast(ushort)sub_entry;
		}
		const(char)* e = internal_validate_track(t.track, t.size, false);
		if (e) {
			error = e;
			goto error3;
		}
	}
	free(sub_table);

	return;

error3:
	free(sub_table);
	for (int trk = 0; trk < s.patterns * 8; trk++)
		free(s.pattern[0][trk].track);
	for (int trk = 0; trk < s.subs; trk++)
		free(s.sub[trk].track);
	free(s.sub);
	free(s.pattern);
error2:
	free(s.order);
error1:
	s.order_length = 0;
	decomp_error = error;
	printf("Can't decompile: %s\n", error);
	return;
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
