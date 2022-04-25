@echo off
    set delay=15
    ping localhost -n %delay%
    net use T: "\\HDA\Anime" /PERSISTENT:yes /SAVECRED
    net use U: "\\HDA\Movies" /PERSISTENT:yes /SAVECRED
    net use V: "\\HDA\Downloads" /PERSISTENT:yes /SAVECRED
    net use W: "\\HDA\OldHD" /PERSISTENT:yes /SAVECRED
    net use X: "\\HDA\tv" /PERSISTENT:yes /SAVECRED
    net use Y: "\\HDA\DesktopContent" /PERSISTENT:yes /SAVECRED
    net use S: "\\HDA\Greyhole Attic" /PERSISTENT:yes /SAVECRED
    net use Z: "\\HDA\Newsgroups" /PERSISTENT:yes /SAVECRED
    net use R: "\\OCTOPI\uploads" /PERSISTENT:yes /SAVECRED
exit
