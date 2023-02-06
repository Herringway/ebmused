module win32.fonts;

import std.exception;
import std.experimental.logger;

import core.stdc.stdio;
import core.sys.windows.windows;
import core.sys.windows.commctrl;

import win32.misc;

private HFONT hFixedFont;
private HFONT hDefaultGUIFont;
private HFONT hTabsFont;
private HFONT hOrderFont;
HFONT oldfont;
COLORREF oldtxt, oldbk;

void set_up_hdc(HDC hdc) nothrow {
	oldfont = SelectObject(hdc, default_font());
	oldtxt = SetTextColor(hdc, GetSysColor(COLOR_WINDOWTEXT));
	oldbk = SetBkColor(hdc, GetSysColor(COLOR_3DFACE));
}

void reset_hdc(HDC hdc) nothrow {
	SelectObject(hdc, oldfont);
	SetTextColor(hdc, oldtxt);
	SetBkColor(hdc, oldbk);
}

void set_up_fonts() nothrow {
	LOGFONT lf;
	LOGFONT lf2;
	NONCLIENTMETRICS ncm = {0};
	// This size is different in 2000 and XP. That could be causing different values to be returned
	// between the Windows SDK and MinGW builds for the new iPaddedBorderWidth field?
	// So don't use that field for now.
	// https://docs.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-nonclientmetricsa#remarks
	ncm.cbSize = NONCLIENTMETRICS.sizeof;
	BOOL ncmInitialized = SystemParametersInfo(SPI_GETNONCLIENTMETRICS, NONCLIENTMETRICS.sizeof, &ncm, 0);

	HFONT h = GetStockObject(ANSI_FIXED_FONT);
	auto err = GetObject(GetStockObject(ANSI_FIXED_FONT), LOGFONT.sizeof, &lf);
	if (err != LOGFONT.sizeof) {
		assumeWontThrow(infof("ANSI_FIXED_FONT: only %d bytes written to lf!\n", err));
		hFixedFont = h;
	} else {
	    lf.lfFaceName = "Consolas\0";
		if (!ncmInitialized) {
			lf.lfHeight = scale_y(lf.lfHeight + 3);
			lf.lfWidth = 0;
		} else {
			// Make the font wide enough to nearly fill the instrument view
			// (Courier New/Consolas are roughly twice as tall as they are wide, and the header has
			// 20 characters)
			lf.lfWidth = (scale_x(180) - ncm.iScrollWidth) / 20;
			lf.lfHeight = lf.lfWidth * 2;
		}
	}

	// TODO: Supposedly it is better to use SystemParametersInfo to get a NONCLIENTMETRICS struct,
	// which contains an appropriate LOGFONT for stuff and changes with theme.
	hDefaultGUIFont = GetStockObject(DEFAULT_GUI_FONT);

	err = GetObject(hDefaultGUIFont, LOGFONT.sizeof, &lf);
	if (err != LOGFONT.sizeof) {
		assumeWontThrow(infof("DEFAULT_GUI_FONT: only %d bytes written to lf!\n", err));
		hOrderFont = GetStockObject(SYSTEM_FONT);
	} else {
	    lf.lfWeight = FW_BOLD;
	    lf.lfHeight = scale_y(16);
	    hTabsFont = CreateFontIndirect(&lf);
	}

	if (!ncmInitialized) {
		err = GetObject(GetStockObject(SYSTEM_FONT), LOGFONT.sizeof, &lf2);
		if (err != LOGFONT.sizeof) {
			printf("SYSTEM_FONT: only %d bytes written to lf2!\n", err);
			hTabsFont = hDefaultGUIFont;
		}
		lf.lfHeight = scale_y(lf2.lfHeight - 1);
		hTabsFont = CreateFontIndirect(&lf);
	} else {
		lf = ncm.lfMessageFont;
		lf.lfHeight = scale_y(16);
		hTabsFont = CreateFontIndirect(&lf);
	}
}

void destroy_fonts() nothrow {
	DeleteObject(hFixedFont);
	DeleteObject(hDefaultGUIFont);
	DeleteObject(hTabsFont);
	DeleteObject(hOrderFont);
}

HFONT fixed_font() nothrow {
	return hFixedFont;
}

HFONT default_font() nothrow {
	return hDefaultGUIFont;
}

HFONT tabs_font() nothrow {
	return hTabsFont;
}

HFONT order_font() nothrow {
	return hOrderFont;
}
