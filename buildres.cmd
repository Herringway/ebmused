@echo off
if not exist src\win32\resource.res (
	rc -r /nologo /fo src\win32\resource.res src\win32\resource.rc
)