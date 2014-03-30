@ECHO OFF
IF NOT "%~f0" == "~f0" GOTO :WinNT
@"jruby.exe" "C:/Users/okano/Dropbox/work/nicovideocomment/scraper/vendor/bundle/jruby/1.9/bin/nokogiri" %1 %2 %3 %4 %5 %6 %7 %8 %9
GOTO :EOF
:WinNT
@"jruby.exe" "%~dpn0" %*
