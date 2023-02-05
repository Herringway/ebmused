import core.sys.windows.windows;
import core.stdc.stdio;
import structs;

// EarthBound related constants
enum NUM_SONGS = 0xBF;
enum NUM_PACKS = 0xA9;
enum BGM_PACK_TABLE = 0x4F70A;
enum PACK_POINTER_TABLE = 0x4F947;
enum SONG_POINTER_TABLE = 0x26298C;

// other constants and stuff
enum MAX_TITLE_LEN = 60;
enum MAX_TITLE_LEN_STR = "60";
