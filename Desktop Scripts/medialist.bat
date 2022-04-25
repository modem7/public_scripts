@echo on

start "" "C:\Users\Alex\Desktop\Desktop Content\Snap2HTML\Snap2HTML.exe" -path:"U:\" -outfile:"W:\PlexMediaList\Movies.html" -title:Movies -silent
start "" "C:\Users\Alex\Desktop\Desktop Content\Snap2HTML\Snap2HTML.exe" -path:"T:\Movies\" -outfile:"W:\PlexMediaList\AnimeMovies.html" -title:"Anime Movies" -silent
start "" "C:\Users\Alex\Desktop\Desktop Content\Snap2HTML\Snap2HTML.exe" -path:"T:\Series\" -outfile:"W:\PlexMediaList\AnimeSeries.html" -title:"Anime Series" -silent
start "" "C:\Users\Alex\Desktop\Desktop Content\Snap2HTML\Snap2HTML.exe" -path:"X:\" -outfile:"W:\PlexMediaList\TV.html" -title:TV -silent
start "" "C:\Users\Alex\Desktop\Desktop Content\Snap2HTML\Snap2HTML.exe" -path:"P:\" -outfile:"W:\PlexMediaList\Standup.html" -title:Standup -silent

exit