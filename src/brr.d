import core.stdc.stdlib;
import structs;
import play;

import std.experimental.logger;

enum {
	BRR_FLAG_END = 1,
	BRR_FLAG_LOOP = 2,
	BRR_BLOCK_SIZE = 9,
};

__gshared sample[128] samp;


ushort sample_ptr_base = 0x6C00;

// Returns the length of a BRR sample, in bytes.
// This makes no attempt to simulate the behavior of the SPC on key on. It ignores the header of a
// block on key on. That would complicate decoding, because you could have a loop that results in a
// sample that ends, or that has a second loop point, and... no one does that. Right?
private int sample_length(const ubyte *spc_memory, ushort start) {
	int end = start;
	ubyte b;
	do {
		b = spc_memory[end];
		end += BRR_BLOCK_SIZE;
	} while ((b & BRR_FLAG_END) == 0 && end < 0x10000 - BRR_BLOCK_SIZE);

	if (end < 0x10000 - BRR_BLOCK_SIZE)
		return end - start;
	else
		return -1;
}

static void decode_brr_block(short *buffer, const ubyte *block, bool first_block) {
	int range = block[0] >> 4;
	int filter = (block[0] >> 2) & 3;

	if (first_block) {
		// According to SPC_DSP, the header is ignored on key on.
		// Not enforcing this could result in a read out of bounds, if the filter is nonzero.
		range = 0;
		filter = 0;
	}

	for (int i = 2; i < 18; i++) {
		int s = block[i / 2];

		if (i % 2 == 0) {
			s >>= 4;
		} else {
			s &= 0x0F;
		}

		if (s >= 8) {
			s -= 16;
		}

		s <<= range;
		s >>= 1;
		if (range > 12) {
			s = (s < 0) ? -(1 << 11) : 0;
		}

		switch (filter) {
			case 1: s += (buffer[-1] * 15) >> 5; break;
			case 2: s += ((buffer[-1] * 61) >> 6) - ((buffer[-2] * 15) >> 5); break;
			case 3: s += ((buffer[-1] * 115) >> 7) - ((buffer[-2] * 13) >> 5); break;
			default: break;
		}

		s *= 2;

		// Clamp to [-65536, 65534] and then have it wrap around at
		// [-32768, 32767]
		if (s < -0x10000) s = (-0x10000 + 0x10000);
		else if (s > 0xFFFE) s = (0xFFFE - 0x10000);
		else if (s < -0x8000) s += 0x10000;
		else if (s > 0x7FFF) s -= 0x10000;

		*buffer++ = cast(short)s;
	}
}

static int get_full_loop_len(const sample *sa, const short *next_block, int first_loop_start) {
	int loop_start = sa.length - sa.loop_len;
	int no_match_found = true;
	while (loop_start >= first_loop_start && no_match_found) {
		// If the first two samples in a loop are the same, the rest all will be too.
		// BRR filters can rely on, at most, two previous samples.
		if (sa.data[loop_start] == next_block[0] &&
				sa.data[loop_start + 1] == next_block[1]) {
			no_match_found = false;
		} else {
			loop_start -= sa.loop_len;
		}
	}

	if (loop_start >= first_loop_start)
		return sa.length - loop_start;
	else
		return -1;
}

void decode_samples(const(ubyte)* ptrtable) {
	for (uint sn = 0; sn < 128; sn++) {
		sample *sa = &samp[sn];
		int start = ptrtable[0] | (ptrtable[1] << 8);
		int loop  = ptrtable[2] | (ptrtable[3] << 8);
		ptrtable += 4;

		sa.data = null;
		if (start == 0 || start == 0xffff)
			continue;

		int length = sample_length(&spc[0], cast(ushort)start);
		if (length == -1)
			continue;

		int end = start + length;
		sa.length = (length / BRR_BLOCK_SIZE) * 16;
		// The LOOP bit only matters for the last brr block
		if (spc[start + length - BRR_BLOCK_SIZE] & BRR_FLAG_LOOP) {
			if (loop < start || loop >= end)
				continue;
			sa.loop_len = ((end - loop) / BRR_BLOCK_SIZE) * 16;
		} else
			sa.loop_len = 0;

		size_t allocation_size = short.sizeof * (sa.length + 1);

		short *p = cast(short*)malloc(allocation_size);
		if (!p) {
			debug tracef("malloc failed in BRR decoding (sn: %02X)\n", sn);
			continue;
		}
/*		printf("Sample %2d: %04X(%04X)-%04X length %d looplen %d\n",
			sn, start, loop, end, sa.length, sa.loop_len);*/

		sa.data = p;

		int needs_another_loop;
		int first_block = true;
		int decoding_start = start;
		int times = 0;

		do {
			needs_another_loop = false;

			for (int pos = decoding_start; pos < end; pos += BRR_BLOCK_SIZE) {
				decode_brr_block(p, &spc[pos], !!first_block);
				p += 16;
				first_block = false;
			}

			if (sa.loop_len != 0) {
				decoding_start = loop;

				short[18] after_loop;
				after_loop[0] = p[-2];
				after_loop[1] = p[-1];

				decode_brr_block(&after_loop[2], &spc[loop], false);
				int full_loop_len = get_full_loop_len(sa, &after_loop[2], (loop - start) / BRR_BLOCK_SIZE * 16);

				if (full_loop_len == -1) {
					needs_another_loop = true;
					//printf("We need another loop! sample %02X (old loop start samples: %d %d)\n", (unsigned)sn,
					//	sa.data[sa.length - sa.loop_len],
					//	sa.data[sa.length - sa.loop_len + 1]);
					ptrdiff_t diff = p - sa.data;
					short *new_stuff = cast(short*)realloc(sa.data, (sa.length + sa.loop_len + 1) * short.sizeof);
					if (new_stuff == null) {
						debug tracef("realloc failed in BRR decoding (sn: %02X)\n", sn);
						// TODO What do we do now? Replace this with something better
						needs_another_loop = false;
						break;
					}
					p = new_stuff + diff;
					sa.length += sa.loop_len;
					sa.data = new_stuff;
				} else {
					sa.loop_len = full_loop_len;
					// needs_another_loop is already false
				}
			}

			// In the vanilla game, the most iterations needed is 48 (for sample 0x17 in pack 5).
			// Most samples need less than 10.
			++times;
		} while (needs_another_loop && times < 64);

		if (needs_another_loop) {
			debug tracef("Sample %02X took too many iterations to get into a cycle\n", sn);
		}

		// Put an extra sample at the end for easier interpolation
		*p = sa.loop_len != 0 ? sa.data[sa.length - sa.loop_len] : 0;
	}
}

void free_samples() {
	for (int sn = 0; sn < 128; sn++) {
		free(samp[sn].data);
		samp[sn].data = null;
	}
}
