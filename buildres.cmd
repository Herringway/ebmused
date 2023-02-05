@echo off
if not exist resources\win32\resource.res (
	rc -r /nologo /fo resources\win32\resource.res resources\win32\resource.rc
)