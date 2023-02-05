import core.sys.windows.windows;
import core.sys.windows.mmsystem;
import std.string;
import ebmusv2;
import win32.misc;

extern(C):

__gshared HMIDIIN hMidiIn = NULL;

private void outputMidiError(uint err) nothrow {
	char[256] errmsg;
	midiInGetErrorTextA(err, &errmsg[0], 255);
	MessageBox2(errmsg.fromStringz, "MIDI Error", MB_ICONEXCLAMATION);
}

void closeMidiInDevice() nothrow {
	if (hMidiIn != NULL) {
		midiInStop(hMidiIn);
		midiInClose(hMidiIn);
		hMidiIn = NULL;
	}
}

void openMidiInDevice(int deviceId, void* callback) nothrow {
	if (deviceId > -1) {
		uint err;
		if ((err = midiInOpen(&hMidiIn, deviceId, cast(DWORD_PTR)callback, 0, CALLBACK_FUNCTION)) != 0) {
			outputMidiError(err);
			return;
		}

		if ((err = midiInStart(hMidiIn)) != 0) {
			midiInClose(hMidiIn);
			outputMidiError(err);
			return;
		}
	}
}
