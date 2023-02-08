USERNAME=haje01
IMAGE=alpaka-tool
version=`cat VERSION.tool`

docker build -t $USERNAME/$IMAGE:latest -f Dockerfile.tool .
docker tag $USERNAME/$IMAGE:latest $USERNAME/$IMAGE:$version
docker login -u haje01
docker push $USERNAME/$IMAGE:latest
docker push $USERNAME/$IMAGE:$version
