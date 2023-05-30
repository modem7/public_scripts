#!/bin/bash -e

# a script that extracts the subtitle file of every mkv movie file and saves it with the same name
# copy to the folder where the mkv files live and run "./mkvextractTracks.sh" in terminal
# options: [trackID]
# example: ./mkvextractTracks.sh 1
#
# info:
# mkvextract is used to extract the subtitles, so mkvtoolnix app (which contains the mkvextract binary) is used:
# https://mkvtoolnix.download/downloads.html
# please adjust below path to point to mkvextract or this script won't work

extractorPath='/Applications/MKVToolNix-9.0.1.app/Contents/MacOS/mkvextract'
defaultTrackID=2
# Ensure we're running in location of script.
cd "`dirname $0`"

if [ $# -gt 0 ]
then
	defaultTrackID=$1
fi

for f in *; do
  if [[ $f == *.mkv ]];
    then
        echo $f
        mkvextract tracks "$f" $defaultTrackID:"${f//mkv/srt}"
  fi
done

echo "Complete"
