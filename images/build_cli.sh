USERNAME=haje01
IMAGE=kafka-cli
version=`cat VERSION.cli`

docker build -t $USERNAME/$IMAGE:latest -f Dockerfile.cli .
docker tag $USERNAME/$IMAGE:latest $USERNAME/$IMAGE:$version
docker push $USERNAME/$IMAGE:latest
docker push $USERNAME/$IMAGE:$version