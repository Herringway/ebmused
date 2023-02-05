import core.stdc.stdio;
import core.stdc.stdlib;
import core.stdc.string;
import core.sys.windows.windows;
import core.sys.windows.commctrl;
import std.exception;
import std.logger;
import std.string;
import std.stdio;
import ebmusv2;
import main;

int fgetw(FILE *f) nothrow {
	int lo, hi;
	lo = fgetc(f); if (lo < 0) return -1;
	hi = fgetc(f); if (hi < 0) return -1;
	return lo | hi<<8;
}

void *array_insert(void **array, int *size, int elemsize, int index) nothrow {
	int new_size = elemsize * ++*size;
	char *a = cast(char*)realloc(*array, new_size);
	index *= elemsize;
	*array = a;
	a += index;
	memmove(a + elemsize, a, new_size - (index + elemsize));
	return a;
}

/*void array_delete(void *array, int *size, int elemsize, int index) {
	int new_size = elemsize * --*size;
	char *a = array;
	index *= elemsize;
	a += index;
	memmove(a, a + elemsize, new_size - index);
}*/

size_t filelength(FILE* f) nothrow {
	fseek(f, 0L, SEEK_END);
	auto size = ftell(f);
	fseek(f, 0L, SEEK_SET);
	return size;
}

char* strlwr(char* str) nothrow {
	import core.stdc.ctype : tolower;
	for(char* p = str; *p != 0;) {
		*p = cast(char)tolower(*p);
	}
	return str;
}

char getc(ref File file) nothrow {
	char[1] buf;
	try {
		file.rawRead(buf[]);
	} catch (Exception) {}
	return buf[0];
}

ushort getw(ref File file) nothrow {
	ushort[1] buf;
	try {
		file.rawRead(buf[]);
	} catch (Exception) {}
	return buf[0];
}
