#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2023 Intel Corporation. All rights reserved.

. "$(dirname "$0")/common"

if [ "$1" == "-h" ]; then
	echo "inject_extent <device_num> <region_id> <offset> <length> <tag>"
	echo "              where cxl-dev<device_num>"
	exit 0
fi

inject_extent $1 $2 $3 $4 $5
