#!/bin/bash

# $1 = the dataset to test
#
# ${@:2} = all other arguments, which get passed to $knn

knn="~/proj/HLearn/dist/build/hlearn-allknn/hlearn-allknn"

tmpdir=$(mktemp -d)
curdir=$(pwd)

dataset=$(basename "$1")

echo "hlearn-allknn -r \"$1\" ${@:2}"

cd "$tmpdir"
#$knn -r "$1" ${@:2} --verbose +RTS -p > stdout 2> stderr
/home/user/proj/HLearn/hlearn-allknn -r "$1" ${@:2} --verbose +RTS -p > stdout 2> stderr
cd "$curdir"

params="params=$(tr ' ' '_' <<< "${@:2}")"
if [ ! -d "$params" ]; then
    mkdir "$params"
fi

if [ -d "$params/$dataset" ]; then
    mv "$params/$dataset" "$params/$dataset.old.$(date +%Y-%m-%d--%H-%M-%S)"
fi

mv "$tmpdir" "./${params}/${dataset}"
