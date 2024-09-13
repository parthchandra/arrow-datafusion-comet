#!/bin/bash
#
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
COMET_HOME_DIR=$SCRIPT_DIR/../..

function usage {
  local NAME=$(basename $0)
  cat <<EOF
Usage: $NAME [options]

This script builds comet native binaries inside a docker image. The image is named
"comet-rm" and will be generated by this script

Options are:

  -r [repo]   : git repo (default: ${REPO})
  -b [branch] : git branch (default: ${BRANCH})
  -t [tag]    : tag for the spark-rm docker image to use for building (default: "latest").
EOF
exit 1
}

function cleanup()
{
  if [ $CLEANUP != 0 ]
  then
    echo Cleaning up ...
    if [ "$(docker ps -a | grep comet-arm64-builder-container)" != "" ]
    then
      docker rm comet-arm64-builder-container
    fi
    if [ "$(docker ps -a | grep comet-amd64-builder-container)" != "" ]
    then
      docker rm comet-amd64-builder-container
    fi
    CLEANUP=0
  fi
}

trap cleanup SIGINT SIGTERM EXIT

CLEANUP=1

REPO="https://github.com/apache/datafusion-comet.git"
BRANCH="release"
MACOS_SDK=
HAS_MACOS_SDK="false"
IMGTAG=latest

while getopts "b:hr:t:" opt; do
  case $opt in
    r) REPO="$OPTARG";;
    b) BRANCH="$OPTARG";;
    t) IMGTAG="$OPTARG" ;;
    h) usage ;;
    \?) error "Invalid option. Run with -h for help." ;;
  esac
done

echo "Building binaries from $REPO/$BRANCH"

WORKING_DIR="$SCRIPT_DIR/comet-rm/workdir"
cp $SCRIPT_DIR/../cargo.config $WORKING_DIR

# TODO: Search for Xcode (Once building macos binaries works)
#PS3="Select Xcode:"
#select xcode_path in  `find . -name "${MACOS_SDK}"`
#do
#  echo "found Xcode in $xcode_path"
#  cp $xcode_path $WORKING_DIR
#  break
#done

if [ -f "${WORKING_DIR}/${MACOS_SDK}" ]
then
  HAS_MACOS_SDK="true"
fi

BUILDER_IMAGE_ARM64="comet-rm-arm64:$IMGTAG"
BUILDER_IMAGE_AMD64="comet-rm-amd64:$IMGTAG"

# Build the docker image in which we will do the build
docker build \
  --platform=linux/arm64 \
  -t "$BUILDER_IMAGE_ARM64" \
  --build-arg HAS_MACOS_SDK=${HAS_MACOS_SDK} \
  --build-arg MACOS_SDK=${MACOS_SDK} \
  "$SCRIPT_DIR/comet-rm"

docker build \
  --platform=linux/amd64 \
  -t "$BUILDER_IMAGE_AMD64" \
  --build-arg HAS_MACOS_SDK=${HAS_MACOS_SDK} \
  --build-arg MACOS_SDK=${MACOS_SDK} \
  "$SCRIPT_DIR/comet-rm"

# Clean previous Java build
pushd $COMET_HOME_DIR && ./mvnw clean && popd

# Run the builder container for each architecture. The entrypoint script will build the binaries

# AMD64
echo "Building amd64 binary"
docker run \
   --name comet-amd64-builder-container \
   --memory 24g \
   --cpus 6 \
   -it \
   --platform linux/amd64 \
   $BUILDER_IMAGE_AMD64 "${REPO}" "${BRANCH}" amd64

if [ $? != 0 ]
then
  echo "Building amd64 binary failed."
  exit 1
fi

# ARM64
echo "Building arm64 binary"
docker run \
   --name comet-arm64-builder-container \
   --memory 24g \
   --cpus 6 \
   -it \
   --platform linux/arm64 \
   $BUILDER_IMAGE_ARM64 "${REPO}" "${BRANCH}" arm64

if [ $? != 0 ]
then
  echo "Building arm64 binary failed."
  exit 1
fi

echo "Building binaries completed"
echo "Copying to java build directories"

JVM_TARGET_DIR=$COMET_HOME_DIR/common/target/classes/org/apache/comet
mkdir -p $JVM_TARGET_DIR

mkdir -p $JVM_TARGET_DIR/linux/amd64
docker cp \
  comet-amd64-builder-container:"/opt/comet-rm/comet/native/target/release/libcomet.so" \
  $JVM_TARGET_DIR/linux/amd64/

if [ "$HAS_MACOS_SDK" == "true" ]
then
  mkdir -p $JVM_TARGET_DIR/darwin/x86_64
  docker cp \
    comet-amd64-builder-container:"/opt/comet-rm/comet/native/target/x86_64-apple-darwin/release/libcomet.dylib" \
    $JVM_TARGET_DIR/darwin/x86_64/
fi

mkdir -p $JVM_TARGET_DIR/linux/aarch64
docker cp \
  comet-arm64-builder-container:"/opt/comet-rm/comet/native/target/release/libcomet.so" \
  $JVM_TARGET_DIR/linux/aarch64/

if [ "$HAS_MACOS_SDK" == "true" ]
then
  mkdir -p $JVM_TARGET_DIR/linux/aarch64
  docker cp \
    comet-arm64-builder-container:"/opt/comet-rm/comet/native/target/aarch64-apple-darwin/release/libcomet.dylib" \
    $JVM_TARGET_DIR/darwin/aarch64/
fi

# Build final jar
echo "Building uber jar and publishing it locally"
pushd $COMET_HOME_DIR

GIT_HASH=$(git rev-parse --short HEAD)
LOCAL_REPO=$(mktemp -d /tmp/comet-staging-repo-XXXXX)

./mvnw  "-Dmaven.repo.local=${LOCAL_REPO}"  -DskipTests install

echo "Installed to local repo: ${LOCAL_REPO}"

popd
