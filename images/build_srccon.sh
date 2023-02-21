USERNAME=haje01
IMAGE=kafka-srccon
version=`cat VERSION.srccon`

docker build -t $USERNAME/$IMAGE:latest -f Dockerfile.srccon .
docker tag $USERNAME/$IMAGE:latest $USERNAME/$IMAGE:$version
docker push $USERNAME/$IMAGE:latest
docker push $USERNAME/$IMAGE:$version