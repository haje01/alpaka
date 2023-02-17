USERNAME=haje01
IMAGE=kafka-sinkcon
version=`cat VERSION.sinkcon`

docker build -t $USERNAME/$IMAGE:latest -f Dockerfile.sinkcon .
docker tag $USERNAME/$IMAGE:latest $USERNAME/$IMAGE:$version
docker push $USERNAME/$IMAGE:latest
docker push $USERNAME/$IMAGE:$version