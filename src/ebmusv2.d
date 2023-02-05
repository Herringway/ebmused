import core.sys.windows.windows;
import core.stdc.stdio;
import structs;

extern(C) nothrow:

pragma(lib, "user32");
pragma(lib, "gdi32");
pragma(lib, "comdlg32");
pragma(lib, "comctl32");
pragma(lib, "winmm");

// EarthBound related constants
enum NUM_SONGS = 0xBF;
enum NUM_PACKS = 0xA9;
enum BGM_PACK_TABLE = 0x4F70A;
enum PACK_POINTER_TABLE = 0x4F947;
enum SONG_POINTER_TABLE = 0x26298C;

// other constants and stuff
enum MAX_TITLE_LEN = 60;
enum MAX_TITLE_LEN_STR = "60";
enum WM_ROM_OPENED = WM_USER;
enum WM_ROM_CLOSED = WM_USER+1;
enum WM_SONG_IMPORTED = WM_USER+2;
enum WM_SONG_LOADED = WM_USER+3;
enum WM_SONG_NOT_LOADED = WM_USER+4;
enum WM_PACKS_SAVED = WM_USER+5;
