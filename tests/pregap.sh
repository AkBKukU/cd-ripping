#!/bin/bash

track="$(cdparanoia -Q 2>&1 | tee | grep " 1. ")"

cdparanoia -t -"$(echo "$track" | awk '{print $4}')" "1[0.0]-1$(echo "$track" | awk '{print $5}')"
