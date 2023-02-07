module win32.handles;

import core.sys.windows.windows;

import win32.inst;
import win32.misc;
import win32.tracker;

enum NUM_TABS = 2;
auto hwndEditor() { return tab_hwnd[0]; }
auto hwndInstruments() { return tab_hwnd[1]; }

__gshared HINSTANCE hinstance;
__gshared HWND hwndMain;
__gshared HMENU hmenu, hcontextmenu;
__gshared HWND[NUM_TABS] tab_hwnd;

__gshared const wchar*[NUM_TABS] tab_class = [
	"ebmused_editor",
	"ebmused_inst",
];
__gshared const char *[NUM_TABS] tab_name = [
	"Sequence Editor",
	"Instruments",
];
__gshared const WNDPROC[NUM_TABS] tab_wndproc = [
	&wrappedWindowsCallback!EditorWndProc,
	&wrappedWindowsCallback!InstrumentsWndProc,
];