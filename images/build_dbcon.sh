USERNAME=haje01
IMAGE=kafka-dbcon
version=`cat VERSION.dbcon`

docker build -t $USERNAME/$IMAGE:latest -f Dockerfile.dbcon .
docker tag $USERNAME/$IMAGE:latest $USERNAME/$IMAGE:$version
docker push $USERNAME/$IMAGE:latest
docker push $USERNAME/$IMAGE:$version