#!/bin/bash
toc=$1
 
# Setup
track=0
index_count=0
audio=0
last_index=""
index="1"
index_count=0
rip=0

mkdir rip

# Begin parsing loop
while IFS=" " read -r type data extra <&9
do
    #echo "For line [$type] found [$data]"
    if [[ "$type" == "TRACK" ]]
    then
        if [[ "$track" != "0" ]]
        then
            audio="$(expr $audio + 1)"
            cdparanoia -w "$index" "rip/$audio-$track.$index_count - Segment.wav"
            echo "Found Track $track"
        fi
        track="$(expr $track + 1)"
        index_count=0
        index="$track"
    fi
    
    
    if [[ "$type" == "INDEX" ]]
    then
        audio="$(expr $audio + 1)"
        last_index="$index"
        index="$track:[$(echo "$data" | sed 's/\(.*\):/\1\./')]"
        cdparanoia -w "$last_index-$index" "rip/$audio-$track.$index_count - Segment.wav"
        index_count="$(expr $index_count + 1)"
    fi

done 9< <(cat $toc)
#done 9< <(cat $toc | sed 's/START/INDEX/g') # Will rip from [00:00.00] to START but causes issues with normal CDs



