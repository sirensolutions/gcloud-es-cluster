ARG ELASTICSEARCH_VERSION

FROM maven:3-jdk-11 as federate-base

ARG FEDERATE_VERSION

WORKDIR /tmp

COPY src/maven/* ./

RUN mvn --settings settings.xml org.apache.maven.plugins:maven-dependency-plugin:2.8:get -Dartifact=io.siren:siren-federate:$FEDERATE_VERSION:zip:proguard-plugin -Dtransitive=false -Ddest=/tmp/federate.zip

ARG ELASTICSEARCH_VERSION

FROM docker.elastic.co/elasticsearch/elasticsearch-oss:${ELASTICSEARCH_VERSION}

COPY --from=federate-base /tmp/federate.zip /tmp/federate.zip

WORKDIR /usr/share/elasticsearch

RUN ./bin/elasticsearch-plugin install -b file:///tmp/federate.zip && \
    rm -rf /tmp/federate.zip && \
    ./bin/elasticsearch-plugin install -b repository-gcs && \
    ./bin/elasticsearch-plugin install -b repository-s3
