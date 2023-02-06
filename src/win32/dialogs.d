module win32.dialogs;

import win32.handles;
import win32.misc;
import misc;
import metadata;
import std.string;
import std.utf;

import core.sys.windows.windows;

__gshared wchar[MAX_PATH] filename;
__gshared OPENFILENAMEW ofn;
alias DialogCallback = extern(Windows) BOOL function(LPOPENFILENAMEW) nothrow;
string open_dialog(DialogCallback func, string filter, string extension, DWORD flags) nothrow {
	try {
		filename[0] = '\0';
		ofn.lStructSize = ofn.sizeof;
		ofn.hwndOwner = hwndMain;
		ofn.lpstrFilter = cast(wchar*)filter.toUTF16z;
		ofn.lpstrDefExt = cast(wchar*)extension.toUTF16z;
		ofn.lpstrFile = &filename[0];
		ofn.nMaxFile = MAX_PATH;
		ofn.Flags = flags | OFN_NOCHANGEDIR;
		return func(&ofn) ? filename.fromStringz.toUTF8 : "";
	} catch (Exception e) {
		filename = '\0';
		return "";
	}
}

BOOL get_original_rom() nothrow {
	string file = open_dialog(&GetOpenFileNameW, "SNES ROM files (*.smc, *.sfc)\0*.smc;*.sfc\0All Files\0*.*\0", null, OFN_FILEMUSTEXIST | OFN_HIDEREADONLY);
	try {
		if (file) {
			open_orig_rom(file);
		}
		metadata_changed |= file != "";
		return !!file;
	} catch (EbmusedException e) {
		MessageBox2(e.msg, e.title, errorClassToIcon(e.errorClass));
		return false;
	} catch (Exception) {
		return false;
	}
}

string openFilePrompt(string filter) nothrow {
	return open_dialog(&GetOpenFileNameW, filter, null, OFN_FILEMUSTEXIST | OFN_HIDEREADONLY);
}
string saveFilePrompt(string filter, string extension) nothrow {
	return open_dialog(&GetSaveFileNameW, filter, extension, OFN_OVERWRITEPROMPT);
}
