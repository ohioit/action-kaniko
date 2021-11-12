#!/busybox/sh
set -e pipefail
set +x

# Process a newline separted list of images where each line has the following format:
#   context image_name tag
# 
# context - the kaniko image build context
# image_name - the image name
# tag - the tag to use for the image
# e.g.
#     resource cad/coi-resource v3.4.0
#     ui cad/coi-uiv 3.4.0 
#
# All image will be pushed to the same registry
#

function ensure() {
    if [ -z "${1}" ]; then
        echo >&2 "Unable to find the ${2} variable. Did you set with: ${2}?"
        exit 1
    fi
}

export REGISTRY=${INPUT_REGISTRY:-"docker.io"}
export USERNAME=${INPUT_USERNAME:-$GITHUB_ACTOR}
export PASSWORD=${INPUT_PASSWORD:-$GITHUB_TOKEN}

ensure "${REGISTRY}" "registry"
ensure "${USERNAME}" "username"
ensure "${PASSWORD}" "password"

export CACHE=${INPUT_CACHE:+"--cache=true"}
export CACHE=$CACHE${INPUT_CACHE_TTL:+" --cache-ttl=$INPUT_CACHE_TTL"}
export CACHE=$CACHE${INPUT_CACHE_REGISTRY:+" --cache-repo=$INPUT_CACHE_REGISTRY"}
export CACHE=$CACHE${INPUT_CACHE_DIRECTORY:+" --cache-dir=$INPUT_CACHE_DIRECTORY"}

export BRANCH=$(echo ${GITHUB_REF} | sed -E "s/refs\/(heads|tags)\///g" | sed -e "s/\//-/g")

if [ -z "${INPUT_IMAGE_LIST}" ]; then
    export INPUT_IMAGE_LIST=".images.${$}"
    export TAG=${INPUT_TAG:-$([ "$BRANCH" == "master" ] && echo latest || echo $BRANCH)}
    export TAG=${TAG:-"latest"}
    export TAG=${TAG#$INPUT_STRIP_TAG_PREFIX}

    echo "${INPUT_PATH} ${INPUT_IMAGE} ${TAG}" > ${INPUT_IMAGE_LIST}
fi

while read -r INPUT_PATH INPUT_IMAGE INPUT_TAG
do
    echo "Processing: context: [${INPUT_PATH}] image: [${INPUT_IMAGE}] tag: [${INPUT_TAG}]"
    export IMAGE=${INPUT_IMAGE}
    export TAG=${INPUT_TAG:-$([ "$BRANCH" == "master" ] && echo latest || echo $BRANCH)}
    export TAG=${TAG:-"latest"}
    export TAG=${TAG#$INPUT_STRIP_TAG_PREFIX}
    export REPOSITORY=$IMAGE
    export IMAGE_LATEST=${INPUT_TAG_WITH_LATEST:+"$IMAGE:latest"}
    export IMAGE=$IMAGE:$TAG
    export CONTEXT_PATH=${INPUT_PATH}

    ensure "${IMAGE}" "image"
    ensure "${TAG}" "tag"
    ensure "${CONTEXT_PATH}" "path"

    if [ "$REGISTRY" == "docker.pkg.github.com" ]; then
        IMAGE_NAMESPACE="$(echo $GITHUB_REPOSITORY | tr '[:upper:]' '[:lower:]')"
        export IMAGE="$IMAGE_NAMESPACE/$IMAGE"
        export REPOSITORY="$IMAGE_NAMESPACE/$REPOSITORY"

        if [ ! -z $IMAGE_LATEST ]; then
            export IMAGE_LATEST="$IMAGE_NAMESPACE/$IMAGE_LATEST"
        fi

        if [ ! -z $INPUT_CACHE_REGISTRY ]; then
            export INPUT_CACHE_REGISTRY="$REGISTRY/$IMAGE_NAMESPACE/$INPUT_CACHE_REGISTRY"
        fi
    fi

    if [ "$REGISTRY" == "docker.io" ]; then
        export REGISTRY="index.${REGISTRY}/v1/"
    else
        export IMAGE="$REGISTRY/$IMAGE"

        if [ ! -z $IMAGE_LATEST ]; then
            export IMAGE_LATEST="$REGISTRY/$IMAGE_LATEST"
        fi
    fi

    export CONTEXT="--context $GITHUB_WORKSPACE/$CONTEXT_PATH"
    export DOCKERFILE="--dockerfile $CONTEXT_PATH/${INPUT_BUILD_FILE:-Dockerfile}"
    export TARGET=${INPUT_TARGET:+"--target=$INPUT_TARGET"}

    if [ ! -z $INPUT_SKIP_UNCHANGED_DIGEST ]; then
        export DESTINATION="--digest-file digest --no-push --tarPath image.tar --destination $IMAGE"
    else
        export DESTINATION="--destination $IMAGE"
        if [ ! -z $IMAGE_LATEST ]; then
            export DESTINATION="$DESTINATION --destination $IMAGE_LATEST"  
        fi
    fi


    export ARGS="$CACHE $CONTEXT $DOCKERFILE $TARGET $DESTINATION $INPUT_EXTRA_ARGS"

    cat <<EOF >/kaniko/.docker/config.json
{
    "auths": {
        "https://${REGISTRY}": {
            "username": "${USERNAME}",
            "password": "${PASSWORD}"
        }
    }
}
EOF

    # https://github.com/GoogleContainerTools/kaniko/issues/1349
    /kaniko/executor --reproducible --force $ARGS

    if [ ! -z $INPUT_SKIP_UNCHANGED_DIGEST ]; then
        export DIGEST=$(cat digest)

        if [ "$REGISTRY" == "docker.pkg.github.com" ]; then
            wget -q -O manifest --header "Authorization: Basic $(echo -n $USERNAME:$PASSWORD | base64)" https://docker.pkg.github.com/v2/$REPOSITORY/manifests/latest || true
            export REMOTE="sha256:$(cat manifest | sha256sum | awk '{ print $1 }')"
        else
            export REMOTE=$(reg digest -u $USERNAME -p $PASSWORD $REGISTRY/$REPOSITORY | tail -1)
        fi

        if [ "$DIGEST" == "$REMOTE" ]; then
            echo "Digest hasn't changed, skipping, $DIGEST"
            echo "Done 🎉️"
            exit 0
        fi

        echo "Pushing image..."

        /kaniko/crane auth login $REGISTRY -u $USERNAME -p $PASSWORD
        /kaniko/crane push image.tar $IMAGE

        if [ ! -z $IMAGE_LATEST ]; then
            echo "Tagging latest..."
            /kaniko/crane tag $IMAGE latest  
        fi
    
        echo "Done 🎉️"
    fi
done < ${INPUT_IMAGE_LIST}
