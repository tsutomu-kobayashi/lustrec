#!/bin/bash

NOW=`date "+%y%m%d%H%M"`
#LUSTREC="../../_build/src/lustrec"
LUSTREC=lustrec
mkdir -p build
build=`pwd`"/build"
while IFS=, read -r file main opts
do
  echo fichier:$file
#   echo main:$main
#   echo opts:$opts
    rm -f witness*
    name=`basename "$file" .lus`
    dir=`dirname "$file"`
    pushd $dir > /dev/null
    if [ "$main" != "" ]; then
	$LUSTREC -d $build -verbose 0 $opts -node $main "$name".lus;
        if [ $? -ne 0 ]; then
          rlustrec1="INVALID";
        else
          rlustrec1="VALID"
	fi
	pushd $build > /dev/null
        gcc -c -Wall -Wno-unused-but-set-variable -I ../../include/ "$name".c > /dev/null
	popd > /dev/null
        if [ $? -ne 0 ]; then
          rgcc1="INVALID";
        else
          rgcc1="VALID"
	fi	
	# Removing Generated lusi file
	#grep generated ../${file}i > /dev/null
	#if [ $? -ne 1 ];then
	#  rm ../${file}i
	#fi
	# Checking inlining
	$LUSTREC -d $build -verbose 0 $opts -inline -witnesses -node $main "$name".lus;
	if [ $? -ne 0 ]; then
          rlustrec2="INVALID";
        else
          rlustrec2="VALID"
	fi
	pushd $build > /dev/null
        gcc -c -Wall -Wno-unused-but-set-variable -I ../../include/ "$name".c > /dev/null
	popd > /dev/null
        if [ $? -ne 0 ]; then
          rgcc2="INVALID";
        else
          rgcc2="VALID"
	fi	
	# Cheching witness
	pushd $build > /dev/null
	lustreh -horn -node check witness.lus 2>/dev/null
	popd > /dev/null
    	z3="`z3 -t:10 witness.smt2 | xargs`"
    	if [ "x`echo $z3 | grep unsat`" == "xunsat" ]; then
	  rinlining="VALID";
	elif [ "x`echo $z3 | xargs | grep -o error`" == "xerror" ]; then
	  rinlining="ERROR";
	elif [ "x`echo $z3 | xargs | grep -o unknown`" == "xunknown" ]; then
	 rinlining="UNKNOWN";
	else
	 rinlining="INVALID"
	 exit 1
        fi  
	# Checking horn backend
	$LUSTREC -horn -d $build -verbose 0 $opts -node $main "$name".lus;
	echo z3 "$name".smt2 | grep unsat
	# TODO: This part of the script has to be optimized
	z3 -t:10 "$name".smt2 | grep unsat > /dev/null
	if [ $? -ne 0 ]; then
         rhorn="INVALID";
        else
         rhorn="VALID"
        fi
	echo "lustrec ($rlustrec1),gcc($rgcc1),lustrec inline ($rlustrec2), gcc inline ($rgcc2), inlining valid ($rinlining),horn ($rhorn),`dirname $file`,`basename $file`,node $main" | column -t -s',' | tee -a ../report-$NOW | grep "INVALID\|ERROR\|UNKNOWN"
    else
	$LUSTREC -d $build -verbose 0 $opts "$name".lus;
        if [ $? -ne 0 ]; then
          rlustrec1="INVALID";
        else
          rlustrec1="VALID"
        fi
	pushd $build > /dev/null
        gcc -c -Wall -Wno-unused-but-set-variable -I ../../include/ "$name".c > /dev/null
	popd > /dev/null
        if [ $? -ne 0 ]; then
          rgcc1="INVALID";
        else
          rgcc1="VALID"
        fi
	$LUSTREC -horn -d $build -verbose 0 $opts ../$file 
	echo "lustrec ($rlustrec1), gcc($rgcc1), horn($rhorn), `dirname $file`,`basename $file`,node $main" | column -t -s',' | tee -a ../report-$NOW | grep "INVALID\|ERROR\|UNKNOWN"
    fi
    popd > /dev/null
done < tests_ok.list
