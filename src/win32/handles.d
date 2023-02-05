module win32.handles;

import core.sys.windows.windows;

import win32.bgmlist;
import win32.inst;
import win32.packlist;
import win32.tracker;

enum NUM_TABS = 4;
auto hwndBGMList() { return tab_hwnd[0]; }
auto hwndInstruments() { return tab_hwnd[1]; }
auto hwndEditor() { return tab_hwnd[2]; }
auto hwndPackList() { return tab_hwnd[3]; }

__gshared HINSTANCE hinstance;
__gshared HWND hwndMain;
__gshared HMENU hmenu, hcontextmenu;
__gshared HWND[NUM_TABS] tab_hwnd;

__gshared const wchar*[NUM_TABS] tab_class = [
	"ebmused_bgmlist",
	"ebmused_inst",
	"ebmused_editor",
	"ebmused_packs"
];
__gshared const char *[NUM_TABS] tab_name = [
	"Song Table",
	"Instruments",
	"Sequence Editor",
	"Data Packs"
];
__gshared const WNDPROC[NUM_TABS] tab_wndproc = [
	&BGMListWndProc,
	&InstrumentsWndProc,
	&EditorWndProc,
	&PackListWndProc,
];