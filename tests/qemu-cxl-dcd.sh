#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2023 Intel Corporation. All rights reserved.

. "$(dirname "$0")/common"

#set -ex

trap 'err $LINENO' ERR

# FIXME make this dynamic to where run_qemu installed ndctl
CXL=/root/ndctl/build/cxl/cxl
DAXCTL=/root/ndctl/build/daxctl/daxctl
cxl_dev_path="/sys/bus/cxl/devices"

# a test tag in Bytes
test_dc_region_id=0
test_ext_offset=(0 134217728)
test_ext_length=(67108864  301989888)
test_tag=dc-test-tag

mem=""
bus=""
serial=""
decoder=""
region=""
dax_dev=""

# FIXME can this be cleaner?
guest_cmd()
{
	cmd=( $@ )
	cmd=("${cmd[@]}" "||" 'echo' 'FAILED : $?')

	#ssh qemu "${cmd[@]}"
	rc=$(ssh qemu "${cmd[@]}")
	echo $rc
}

check_extent_cnt()
{
	region=$1
	expected=$2
	cnt=$(guest_cmd "ls" "-la" "${cxl_dev_path}/${region}/dax_${region}/extent*/length" "|" "wc" "-l")
	if [ "$cnt" != "$expected" ]; then
		echo "FAIL found $cnt extents; expected $expected"
		err "$LINENO"
	fi
}

create_dcd_region()
{
	mem="$1"
	decoder="$2"

	# create region
	region=$(guest_cmd "$CXL" 'create-region' '-t' "dc${test_dc_region_id}" '-d' "$decoder" '-m' "$mem" '|' 'jq' '-r' '.region')

	if [[ ! $region ]]; then
		echo "create-region failed for $decoder / $mem"
		err "$LINENO"
	fi
	echo $region
}

check_region()
{
	search=$1
	result=$(guest_cmd "$CXL" 'list' '-r' "$search" '|' 'jq' '-r' ".[].region")

	if [ "$result" != "$search" ]; then
		echo "check region failed to find $search"
		err "$LINENO"
	fi
	echo "TEST: region:${result}"
}

check_not_region()
{
	search=$1

	result=$($CXL list -r "$search" | jq -r ".[].region")
	if [ "$result" == "$search" ]; then
		echo "check not region failed; $search found"
		err "$LINENO"
	fi
}

destroy_region()
{
	region=$1
	guest_cmd "$CXL" "disable-region" "$region"
	guest_cmd "$CXL" "destroy-region" "$region"
}

create_dax_dev()
{
	reg="$1"

	guest_cmd "$DAXCTL" "create-device" "-r" "$reg"
	dax_dev=$(guest_cmd "$DAXCTL" "list" "-r" "$reg" "-D" "|" "jq" "-er" "'.[].chardev'")
}

check_dax_dev()
{
	search="$1"
	size="$2"
	#let size=$((size * 1024 * 1024))
	result=$(guest_cmd "$DAXCTL" "list" "-d" "$search" "|" "jq" "-er" "'.[].chardev'")
	if [ "$result" != "$search" ]; then
		echo "check dax device failed to find $search"
		err "$LINENO"
	fi
	result=$(guest_cmd "$DAXCTL" "list" "-d" "$search" "|" "jq" "-er" "'.[].size'")
	if [ "$result" != "$size" ]; then
		echo "check dax device failed incorrect size $result; exp $size"
		err "$LINENO"
	fi
}

check_not_dax_dev()
{
	reg="$1"
	search="$2"

	result=$(guest_cmd "$DAXCTL" "list" "-r" "$reg" "-D" "|" "jq" "-er" "'.[].chardev'")
	if [ "$result" == "$search" ]; then
		echo "FAIL found $result"
		err "$LINENO"
	fi
}

destroy_dax_dev()
{
	dev="$1"

	guest_cmd "$DAXCTL" "disable-device" "$dev"
	guest_cmd "$DAXCTL" "destroy-device" "$dev"
}


# main()
guest_cmd 'modprobe' '-r' 'cxl_test'
guest_cmd 'modprobe' 'cxl_acpi'
guest_cmd 'modprobe' 'cxl_port'
guest_cmd 'modprobe' 'cxl_mem'

readarray -t memdevs < <(guest_cmd "${CXL}" 'list' '-b' 'ACPI.CXL' '-Mi' '|' "jq" "-r" "'.[].memdev'")
for mem in ${memdevs[@]}; do
	dcsize=$(guest_cmd "$CXL" 'list' '-m' "$mem" '|' 'jq' '-r' "'.[].dc${test_dc_region_id}_size'")
	if [ "$dcsize" == "null" ]; then
		continue
	fi
	decoder=$(guest_cmd "$CXL" "list" "-b" "ACPI.CXL" "-D" "-d" "root" "-m" "$mem" "|" "jq" "-r" "'.[]" "|" "select(.dc${test_dc_region_id}_capable" "==" "true)" "|" "select(.nr_targets" "==" "1)" "|" "select(.size" ">=" "${dcsize})" "|" ".decoder'")
	if [[ $decoder ]]; then
		bus=$(guest_cmd "$CXL" "list" "-b" "ACPI.CXL" "-m" "${mem}" "|" "jq" "-r" "'.[].bus'")
		serial=$(guest_cmd "$CXL" "list" "-m" "$mem" "|" "jq" "-r" "'.[].serial'")
		break
	fi
done

echo "TEST: DCD test device bus:${bus} decoder:${decoder} mem:${mem} serial:${serial}"

if [ "$decoder" == "" ] || [ "$serial" == "" ]; then
	echo "No mem device/decoder found with DCD support"
	exit 77
fi

#create_dcd_region ${mem} ${decoder}

#check_region ${region}

inject_extent ${serial} ${test_dc_region_id} ${test_ext_offset[0]} ${test_ext_length[0]} ${test_tag}

exit 0

check_extent_cnt ${region} 1

create_dax_dev ${region}

check_dax_dev ${dax_dev} ${test_ext_length[0]}

# Remove the pre-created test extent out from under dax device
# stack should hold ref until dax device deleted
echo ""
echo "Test: Remove pre-created test extent"
echo ""
remove_extent ${serial} ${test_dc_region_id} ${test_ext_offset[0]} ${test_ext_length[0]}

check_extent_cnt ${region} 1
check_dax_dev ${dax_dev} ${test_ext_length[0]}

destroy_dax_dev ${dax_dev}
check_not_dax_dev ${region} ${dax_dev}

check_extent_cnt ${region} 1

remove_extent ${serial} ${test_dc_region_id} ${test_ext_offset[0]} ${test_ext_length[0]}
check_extent_cnt ${region} 0


inject_extent ${serial} ${test_dc_region_id} ${test_ext_offset[0]} ${test_ext_length[0]} ${test_tag}
inject_extent ${serial} ${test_dc_region_id} ${test_ext_offset[1]} ${test_ext_length[1]} ${test_tag}

check_extent_cnt ${region} 2

create_dax_dev ${region}
ext_sum_length="$((${test_ext_length[0]} + ${test_ext_length[1]}))"
check_dax_dev ${dax_dev} $ext_sum_length

remove_extent ${serial} ${test_dc_region_id} ${test_ext_offset[0]} ${test_ext_length[0]}
check_extent_cnt ${region} 2
remove_extent ${serial} ${test_dc_region_id} ${test_ext_offset[1]} ${test_ext_length[1]}
check_extent_cnt ${region} 2
destroy_dax_dev ${dax_dev}
check_not_dax_dev ${region} ${dax_dev}
check_extent_cnt ${region} 0


# Test partial extent remove
inject_extent ${serial} ${test_dc_region_id} ${test_ext_offset[0]} ${test_ext_length[0]} ${test_tag}
create_dax_dev ${region}
partial_ext_dpa="$((${test_ext_offset[0]} + (${test_ext_length[0]} / 2)))"
partial_ext_length="$((${test_ext_length[0]} / 2))"
echo "Removing Partial : $partial_ext_dpa $partial_ext_length"
remove_extent ${serial} ${test_dc_region_id} ${partial_ext_dpa} ${partial_ext_length}
check_extent_cnt ${region} 1
destroy_dax_dev ${dax_dev}
check_not_dax_dev ${region} ${dax_dev}
check_extent_cnt ${region} 0


# Test multiple extent remove
# Not done yet.
inject_extent ${serial} ${test_dc_region_id} ${test_ext_offset[0]} ${test_ext_length[0]} ${test_tag}
inject_extent ${serial} ${test_dc_region_id} ${test_ext_offset[1]} ${test_ext_length[1]} ${test_tag}
check_extent_cnt ${region} 2
create_dax_dev ${region}
partial_ext_dpa="$((${test_ext_offset[0]} + (${test_ext_length[0]} / 2)))"
partial_ext_length="$((${test_ext_offset[1]} - ${test_ext_offset[0]}))"
echo "Removing multiple in span : $partial_ext_dpa $partial_ext_length"
remove_extent ${serial} ${test_dc_region_id} ${partial_ext_dpa} ${partial_ext_length}
check_extent_cnt ${region} 2
destroy_dax_dev ${dax_dev}
check_not_dax_dev ${region} ${dax_dev}
check_extent_cnt ${region} 0

inject_extent ${serial} ${test_dc_region_id} ${test_ext_offset[0]} ${test_ext_length[0]} ${test_tag}
inject_extent ${serial} ${test_dc_region_id} ${test_ext_offset[1]} ${test_ext_length[1]} ${test_tag}
check_extent_cnt ${region} 2

destroy_region ${region}

# region should come down even with extents
check_not_region ${region}



echo "IKW TEST PASSED!!!!!"
exit 0
