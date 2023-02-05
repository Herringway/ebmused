import core.stdc.stdio;
import core.stdc.stdlib;
import core.stdc.string;
import std.string;
import ebmusv2;
import structs;
import main;
import misc;
import parser;
import play;
import song;

extern(C):

void order_insert(int pos, int pat) nothrow {
	int *p = cast(int*)array_insert(cast(void**)&cur_song.order, &cur_song.order_length,
		int.sizeof, pos);
	*p = pat;

	if (cur_song.repeat_pos >= pos)
		cur_song.repeat_pos++;

	if (state.ordnum >= pos) {
		state.ordnum++;
		pattop_state.ordnum++;
	}
}

void order_delete(int pos) nothrow {
	memmove(&cur_song.order[pos], &cur_song.order[pos+1],
		(--cur_song.order_length - pos) * int.sizeof);
	if (cur_song.repeat_pos > pos)
		cur_song.repeat_pos--;
	if (state.ordnum > pos) {
		state.ordnum--;
		pattop_state.ordnum--;
	}
}

track *pattern_insert(int pat) nothrow {
	cur_song.pattern = cast(track[8]*)realloc(cur_song.pattern, ++cur_song.patterns * track.sizeof * 8);
	memmove(&cur_song.pattern[pat+1], &cur_song.pattern[pat], (cur_song.patterns - (pat+1)) * track.sizeof * 8);

	// Update the order to reflect the renumbered patterns
	for (int i = 0; i < cur_song.order_length; i++)
		if (cur_song.order[i] >= pat)
			cur_song.order[i]++;

	return &cur_song.pattern[pat][0];
}

void pattern_delete(int pat) nothrow {
	for (int i = 0; i < 8; i++)
		free(cur_song.pattern[pat][i].track);
	memmove(&cur_song.pattern[pat], &cur_song.pattern[pat+1], (--cur_song.patterns - pat) * track.sizeof * 8);

	for (int i = 0; i < cur_song.order_length; ) {
		if (cur_song.order[i] == pat) {
			order_delete(i);
			continue;
		}
		if (cur_song.order[i] > pat) cur_song.order[i]--;
		i++;
	}
}

bool split_pattern(int pos) nothrow {
	song_state split_state;
	char[32] buf;
	int ch;
	if (pos == 0) return false;
	split_state = pattop_state;
	while (split_state.patpos < pos) {
		if (!do_cycle_no_sound(&split_state)) return false;
	}
	for (ch = 0; ch < 8; ch++) {
		channel_state *c = &split_state.chan[ch];
		if (c.sub_count && *c.ptr != '\0') {
			sprintf(&buf[0], "Track %d is inside a subroutine", ch);
			MessageBox2(buf.fromStringz, "Cannot split", 48/*MB_ICONEXCLAMATION*/);
			return false;
		}
		if (c.next != 0) {
			sprintf(&buf[0], "Track %d is inside a note", ch);
			MessageBox2(buf.fromStringz, "Cannot split", 48/*MB_ICONEXCLAMATION*/);
			return false;
		}
	}
	int this_pat = cur_song.order[split_state.ordnum];
	track *ap = pattern_insert(this_pat + 1);
	track *bp = ap - 8;
	for (ch = 0; ch < 8; ch++) {
		channel_state *c = &split_state.chan[ch];
		ubyte *splitptr = c.sub_count ? c.sub_ret : c.ptr;
		if (splitptr == null) {
			ap[ch].size = 0;
			ap[ch].track = null;
			continue;
		}
		int before_size = cast(int)(splitptr - bp[ch].track);
		int after_size = bp[ch].size - before_size;

		int after_subcount = c.sub_count ? c.sub_count - 1 : 0;
		if (after_subcount) {
			after_size += 4;
			splitptr -= 4;
			splitptr[3] -= after_subcount;
		}

		ap[ch].size = after_size;
		ap[ch].track = cast(ubyte*)memcpy(malloc(after_size + 1), splitptr, after_size + 1);
		if (after_subcount)
			ap[ch].track[3] = cast(ubyte)after_subcount;

		bp[ch].size = before_size;
		bp[ch].track[before_size] = 0;
	}
	for (int i = 0; i < cur_song.order_length; i++)
		if (cur_song.order[i] == this_pat)
			order_insert(i + 1, this_pat + 1);
	return true;
}

bool join_patterns() nothrow {
	char[60] buf;
	if (state.ordnum+1 == cur_song.order_length)
		return false;
	int this_pat = cur_song.order[state.ordnum];
	int next_pat = cur_song.order[state.ordnum+1];
	int i;
	if (this_pat == next_pat) {
		MessageBox2("Next pattern is same as current", "Cannot join", 48);
		return false;
	}
	for (i = 0; i < cur_song.order_length; i++) {
		if (cur_song.order[i] == this_pat) {
			i++;
			if (i == cur_song.order_length
			 || i == cur_song.repeat_pos
			 || cur_song.order[i] != next_pat) goto nonconsec;
		} else if (cur_song.order[i] == next_pat) {
nonconsec:
			sprintf(&buf[0], "Patterns %d and %d are not always consecutive",
				this_pat, next_pat);
error:
			MessageBox2(buf.fromStringz, "Cannot join", 48/*MB_ICONEXCLAMATION*/);
			return false;
		}
	}
	track *tp = &cur_song.pattern[this_pat][0];
	track *np = &cur_song.pattern[next_pat][0];
	for (i = 0; i < 8; i++) {
		if (tp[i].track == null && np[i].track != null) {
			sprintf(&buf[0], "Track %d active in pattern %d but not in %d",
				i, next_pat, this_pat);
			goto error;
		} else if (tp[i].track != null && np[i].track == null) {
			sprintf(&buf[0], "Track %d active in pattern %d but not in %d",
				i, this_pat, next_pat);
			goto error;
		}
	}
	for (i = 0; i < 8; i++) {
		if (tp[i].track == null) continue;
		int oldsize = tp[i].size;
		tp[i].size += np[i].size;
		tp[i].track = cast(ubyte*)realloc(tp[i].track, tp[i].size + 1);
		memcpy(tp[i].track + oldsize, np[i].track, np[i].size + 1);
	}
	pattern_delete(next_pat);
	return true;
}

// Check to see if a part of a track can be made into a subroutine
static int check_repeat(ubyte *sub, int subsize, ubyte *p, int size) nothrow {
	if (size % subsize != 0) return 0;
	int cnt = size / subsize;
	if (cnt > 255) return 0;
	for (int i = 0; i < cnt; i++) {
		if (memcmp(p, sub, subsize) != 0) return 0;
		p += subsize;
	}
	return cnt;
}

int create_sub(ubyte *start, ubyte *end, int *count) nothrow {
	int size = cast(int)(end - start);
	int sub;
	int subsize;
	int cnt;

	for (sub = 0; sub < cur_song.subs; sub++) {
		track *t = &cur_song.sub[sub];
		subsize = t.size;
		if (subsize == 0) continue;
		cnt = check_repeat(t.track, subsize, start, size);
		if (cnt) {
			*count = cnt;
			return sub;
		}
	}

	if (!validate_track(start, size, true))
		return -1;

	ubyte *p = start;
	while (p < end) {
		p = next_code(p);
		subsize = cast(int)(p - start);
		cnt = check_repeat(start, subsize, start, size);
		// eventually p will reach end, and this must succeed
		if (cnt) {
			track *t = cast(track*)array_insert(cast(void**)&cur_song.sub, &cur_song.subs,
				track.sizeof, sub);
			t.size = subsize;
			t.track = cast(ubyte*)memcpy(malloc(subsize + 1), start, subsize);
			t.track[subsize] = '\0';
			*count = cnt;
			return sub;
		}
	}
	// should never get here
	return -1;
}

