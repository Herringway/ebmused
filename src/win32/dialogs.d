module win32.dialogs;

import win32.handles;
import metadata;

import core.sys.windows.windows;

__gshared char[MAX_PATH] filename;
__gshared OPENFILENAMEA ofn;
alias DialogCallback = extern(Windows) BOOL function(LPOPENFILENAMEA) nothrow;
char *open_dialog(DialogCallback func,
	char *filter, char *extension, DWORD flags) nothrow
{
	filename[0] = '\0';
	ofn.lStructSize = ofn.sizeof;
	ofn.hwndOwner = hwndMain;
	ofn.lpstrFilter = filter;
	ofn.lpstrDefExt = extension;
	ofn.lpstrFile = &filename[0];
	ofn.nMaxFile = MAX_PATH;
	ofn.Flags = flags | OFN_NOCHANGEDIR;
	return func(&ofn) ? &filename[0] : NULL;
}

BOOL get_original_rom() nothrow {
	char *file = open_dialog(&GetOpenFileNameA,
		cast(char*)"SNES ROM files (*.smc, *.sfc)\0*.smc;*.sfc\0All Files\0*.*\0".ptr,
		NULL,
		OFN_FILEMUSTEXIST | OFN_HIDEREADONLY);
	try {
		bool ret = file && open_orig_rom(file);
		metadata_changed |= ret;
		return ret;
	} catch (Exception) {
		return false;
	}
}