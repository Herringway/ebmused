@echo off
if not exist src\resource.res (
	rc -r /nologo /fo src\resource.res src\resource.rc
)