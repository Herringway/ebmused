import core.stdc.ctype;
import core.stdc.stdio;
import core.stdc.stdlib;
import std.format;
import std.string;
import structs;
import misc;
import parser;
import song;

private int unhex(int chr) nothrow @safe {
	if (chr >= '0' && chr <= '9')
		return chr - '0';
	chr |= 0x20; // fold to lower case
	if (chr >= 'a' && chr <= 'f')
		return chr - 'a' + 10;
	return -1;
}

uint calc_track_size_from_text(char *p) {
	int size = 0;
	while (*p) {
		int c = *p++;
		if (unhex(c) >= 0) {
			if (unhex(*p) >= 0) p++;
			size++;
		} else if (c == '[' || c == ']' || isspace(c)) {
			// nothing
		} else if (c == '*') {
			strtol(p, &p, 10);
			if (*p == ',') strtol(p + 1, &p, 10);
			size += 4;
		} else {
			throw new EbmusedWarningException(format!"Bad character: '%s'"(c), "");
		}
	}
	return size;
}

// returns 1 if successful
void text_to_track(char[] str, ref track t, bool is_sub) {
	ubyte *data;
	int size = calc_track_size_from_text(&str[0]);

	int pos;
	if (size == 0 && !is_sub) {
		data = null;
	} else {
		data = cast(ubyte*)malloc(size + 1);
		char *p = &str[0];
		pos = 0;
		while (*p) {
			int c = *p++;
			int h = unhex(c);
			if (h >= 0) {
				int h2 = unhex(*p);
				if (h2 >= 0) { h = h << 4 | h2; p++; }
				data[pos++] = cast(ubyte)h;
			} else if (c == '*') {
				int sub = strtol(p, &p, 10);
				int count = *p == ',' ? strtol(p + 1, &p, 10) : 1;
				data[pos++] = 0xEF;
				data[pos++] = sub & 0xFF;
				data[pos++] = cast(ubyte)(sub >> 8);
				data[pos++] = cast(ubyte)(count);
			}
		}
		data[pos] = '\0';
	}
	scope(failure) {
		if (data !is null) {
			free(data);
		}
	}

	validate_track(data, size, is_sub);

	if (size != t.size || (data[0 .. size] != t.track[0 .. size])) {
		t.size = size;
		free(t.track);
		t.track = data;
	} else {
		free(data);
	}
}

//// includes ending '\0'
int text_length(ubyte *start, ubyte *end) {
	import std.experimental.logger;
	int textlength = 0;
	for (ubyte *p = start; p < end; ) {
		int byte_ = *p;
		int len;
		if (byte_ < 0x80) {
			len = p[1] < 0x80 ? 2 : 1;
			textlength += 3*len + 2;
		} else if (byte_ < 0xE0) {
			len = 1;
			textlength += 3;
		} else {
			len = 1 + code_length.ptr[byte_ - 0xE0];
			if (byte_ == 0xEF) {
				char[12] buf = 0;
				textlength += sformat!"*%d,%d "(buf[], p[1] | p[2] << 8, p[3]).length;
			} else {
				textlength += 3*len + 2;
			}
		}
		p += len;
	}
	return textlength;
}

//// convert a track to text. size must not be 0
void track_to_text(char[] out_, ubyte *track, int size) nothrow {
	out_[$ - 1] = '\0';
	for (int len, pos = 0; pos < size; pos += len) {
		int byte_ = track[pos];

		len = cast(int)(next_code(&track[pos]) - &track[pos]);

		if (byte_ == 0xEF) {
			int sub = track[pos+1] | track[pos+2] << 8;
			out_ = out_[sprintf(&out_[0], "*%d,%d", sub, track[pos + 3]) .. $];
		} else {
			int i;
			if (byte_ < 0x80 || byte_ >= 0xE0) {
				out_[0] = '[';
				out_ = out_[1 .. $];
			}
			for (i = 0; i < len; i++) {
				int byte2_ = track[pos + i];
				if (i != 0) {
					out_[0] = ' ';
					out_ = out_[1 .. $];
				}
				out_[0] = "0123456789ABCDEF"[byte2_ >> 4];
				out_[1] = "0123456789ABCDEF"[byte2_ & 15];
				out_ = out_[2 .. $];
			}
			if (byte_ < 0x80 || byte_ >= 0xE0) {
				out_[0] = ']';
				out_ = out_[1 .. $];
			}
		}

		out_[0] = ' ';
		out_ = out_[1 .. $];
	}
}
